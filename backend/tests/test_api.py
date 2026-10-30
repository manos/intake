import sqlite3
from uuid import uuid4

import pytest
import xlrd
from fastapi.testclient import TestClient


def test_api_contract(tmp_path):
    from backend.app import create_app
    from backend.db import backup, create_user

    app = create_app(tmp_path)
    create_user(app.state.db, "alpha", "long synthetic password")
    create_user(app.state.db, "beta", "different synthetic password")
    a = TestClient(app)
    assert a.get("/api/me").status_code == 401
    a.auth = ("alpha", "long synthetic password")
    assert a.get("/api/me").json()["settings"]["timezone"] == "UTC"
    item_id = str(uuid4())
    data = {
        "name": "Example",
        "color": "#123abc",
        "unit": "unit",
        "amount": "0.125",
        "presets": ["0.125"],
        "archived": False,
        "order": 0,
    }
    op = {
        "id": str(uuid4()),
        "entity": "item",
        "record_id": item_id,
        "base_version": 0,
        "data": data,
        "deleted": False,
    }

    def sync(ops, cursor=0):
        return a.post("/api/sync", json={"operations": ops, "cursor": cursor}).json()

    first = sync([op])
    assert first["results"][0]["status"] == "applied"
    assert sync([op])["results"] == first["results"]
    assert len(sync([])["changes"]) == 1
    changed = dict(op, data=dict(data, name="Other"))
    assert sync([changed])["results"][0]["status"] == "invalid"
    conflict = dict(changed, id=str(uuid4()))
    assert sync([conflict])["results"][0]["status"] == "conflict"
    a.auth = ("beta", "different synthetic password")
    assert sync([])["changes"] == []
    entry = {
        "item_id": item_id,
        "quantity": "1.25",
        "unit": "unit",
        "item_name": "Example",
        "color": "#123abc",
        "occurred_at": "2026-01-01T12:00:00+00:00",
        "timezone": "UTC",
        "note": "",
    }
    assert (
        sync(
            [
                dict(
                    op,
                    id=str(uuid4()),
                    entity="entry",
                    record_id=str(uuid4()),
                    data=entry,
                )
            ]
        )["results"][0]["status"]
        == "invalid"
    )
    a.auth = ("alpha", "long synthetic password")
    assert (
        a.put(
            "/api/settings", json={"timezone": "Invalid/Zone", "day_start": 0}
        ).status_code
        == 422
    )
    assert (
        a.put("/api/settings", json={"timezone": "UTC", "day_start": 4}).status_code
        == 200
    )
    assert (
        a.post(
            "/api/sync",
            json={"operations": [], "cursor": 0},
            headers={"origin": "https://evil.example"},
        ).status_code
        == 403
    )
    export = a.post(
        "/api/export", json={"items": [first["changes"][0]], "entries": [], "days": []}
    )
    assert export.status_code == 200
    assert export.content[:8] == bytes.fromhex("d0cf11e0a1b11ae1")
    book = xlrd.open_workbook(file_contents=export.content)
    assert book.sheet_by_name("Items").cell_value(1, 1) == "Example"
    target = tmp_path / "backup.sqlite3"
    backup(app.state.db, target)
    with sqlite3.connect(target) as db:
        assert db.execute("select count(*) from users").fetchone()[0] == 2


@pytest.fixture
def client(tmp_path):
    from backend.app import create_app
    from backend.db import create_user

    app = create_app(tmp_path)
    create_user(app.state.db, "sample", "synthetic password long")
    with TestClient(app) as client:
        client.auth = ("sample", "synthetic password long")
        yield client


def item_operation(**changes):
    data = {
        "name": "Example",
        "color": "#123abc",
        "unit": "unit",
        "amount": "0.123456789123456789",
        "presets": ["0.25"],
        "archived": False,
        "order": 0,
    }
    result = {
        "id": str(uuid4()),
        "entity": "item",
        "record_id": str(uuid4()),
        "base_version": 0,
        "data": data,
        "deleted": False,
    }
    result.update(changes)
    return result


def send(client, operations, cursor=0):
    response = client.post(
        "/api/sync", json={"operations": operations, "cursor": cursor}
    )
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.parametrize(
    "field,value",
    [
        ("amount", True),
        ("amount", "NaN"),
        ("amount", "Infinity"),
        ("amount", 0),
        ("amount", -1),
        ("name", ""),
        ("color", "#12"),
        ("presets", [-1]),
        ("archived", "false"),
        ("order", False),
        ("unexpected", "value"),
    ],
)
def test_invalid_records_do_not_create_changes(client, field, value):
    op = item_operation()
    op["data"][field] = value
    result = send(client, [op])
    assert result["results"][0]["status"] == "invalid"
    assert result["changes"] == []
    assert send(client, [op])["results"] == result["results"]


def test_ownership_cannot_be_supplied(client):
    op = item_operation(user_id="other")
    assert send(client, [op])["results"][0]["status"] == "invalid"
    assert send(client, [])["changes"] == []


def test_history_survives_archival_deletion_and_stale_write(client):
    item = item_operation()
    send(client, [item])
    item = dict(item, id=str(uuid4()), base_version=1, deleted=True, data={})
    send(client, [item])
    entry = item_operation(
        entity="entry",
        data={
            "item_id": item["record_id"],
            "quantity": "0.01",
            "unit": "historic",
            "item_name": "Historic Name",
            "color": "#aaaaaa",
            "occurred_at": "2026-01-01T00:01:00-07:00",
            "timezone": "America/Denver",
            "note": "",
        },
    )
    applied = send(client, [entry])
    assert applied["results"][0]["status"] == "applied"
    assert applied["results"][0]["record"]["data"]["unit"] == "historic"
    stale = dict(item, id=str(uuid4()), base_version=0)
    assert send(client, [stale])["results"][0]["record"]["version"] == 2


def test_changes_pagination_has_no_gaps_or_repeats(client):
    first = send(client, [item_operation() for _ in range(500)])
    send(client, [item_operation() for _ in range(7)])
    first = send(client, [])
    assert len(first["changes"]) == 500
    assert first["has_more"] is True
    second = send(client, [], first["cursor"])
    assert len(second["changes"]) == 7
    assert second["has_more"] is False
    assert not (
        {r["id"] for r in first["changes"]} & {r["id"] for r in second["changes"]}
    )
    assert send(client, [], second["cursor"])["changes"] == []


def test_xls_literals_and_decimal_precision(client):
    op = item_operation()
    op["data"]["name"] = "=1+1"
    row = send(client, [op])["results"][0]["record"]
    response = client.post(
        "/api/export", json={"items": [row], "entries": [], "days": []}
    )
    sheet = xlrd.open_workbook(file_contents=response.content).sheet_by_name("Items")
    assert sheet.cell_value(1, 1) == "=1+1"
    assert sheet.cell_value(1, 3) == "0.123456789123456789"
    assert sheet.cell_type(1, 1) == xlrd.XL_CELL_TEXT


def test_malformed_request_lengths_do_not_crash(client):
    assert (
        client.post(
            "/api/sync", content="{}", headers={"content-length": "garbage"}
        ).status_code
        == 400
    )


def test_origin_body_and_security_headers(client):
    assert (
        client.post("/api/sync", content=b"x" * (4 * 1024 * 1024 + 1)).status_code
        == 413
    )
    assert (
        client.post(
            "/api/sync",
            json={"operations": [], "cursor": 0},
            headers={"sec-fetch-site": "cross-site"},
        ).status_code
        == 403
    )
    assert client.get("/api/me").headers["cache-control"] == "private, no-store"
    assert (
        "frame-ancestors 'none'" in client.get("/").headers["content-security-policy"]
    )
    assert client.get("/api/missing").status_code == 404


def test_throttle_persists_across_restart(tmp_path):
    from backend.app import create_app
    from backend.db import create_user

    app = create_app(tmp_path)
    create_user(app.state.db, "sample", "long synthetic password")
    client = TestClient(app)
    client.auth = ("sample", "wrong")
    for _ in range(6):
        assert client.get("/api/me").status_code == 401
    restarted = TestClient(create_app(tmp_path))
    restarted.auth = ("sample", "long synthetic password")
    response = restarted.get("/api/me")
    assert response.status_code == 429
    assert int(response.headers["retry-after"]) >= 1


def test_password_hash_and_backup_refuses_overwrite(tmp_path):
    from backend.db import backup, create_user, initialize

    path = initialize(tmp_path)
    with pytest.raises(ValueError):
        create_user(path, "sample", "short")
    create_user(path, "sample", "long synthetic password")
    with sqlite3.connect(path) as db:
        salt, password = db.execute("select salt,password from users").fetchone()
        assert len(salt) == 32
        assert password != b"long synthetic password"
    with pytest.raises(FileExistsError):
        backup(path, path)


def test_restored_database_detects_stale_cursor(client):
    response = client.post("/api/sync", json={"operations": [], "cursor": 99999})
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "cursor_reset"


def test_trusted_public_origin_is_explicit(tmp_path, monkeypatch):
    from backend.app import create_app

    monkeypatch.setenv("PUBLIC_ORIGIN", "https://intake.example.ts.net")
    client = TestClient(create_app(tmp_path))
    response = client.post(
        "/api/sync",
        json={"operations": [], "cursor": 0},
        headers={"origin": "https://intake.example.ts.net"},
    )
    assert response.status_code == 401
    assert (
        client.post(
            "/api/sync", json={}, headers={"origin": "https://other.example.ts.net"}
        ).status_code
        == 403
    )


def test_unicode_password_is_usable(tmp_path):
    import base64

    from backend.app import create_app
    from backend.db import create_user

    app = create_app(tmp_path)
    create_user(app.state.db, "sample", "synthetic 🔐 password")
    encoded = base64.b64encode("sample:synthetic 🔐 password".encode()).decode()
    assert (
        TestClient(app)
        .get("/api/me", headers={"authorization": "Basic " + encoded})
        .status_code
        == 200
    )


@pytest.mark.parametrize(
    "field,value",
    [
        ("occurred_at", "2026-01-01T00:00:00"),
        ("occurred_at", "invalid"),
        ("timezone", "../UTC"),
        ("quantity", "-0.1"),
        ("item_id", "not-uuid"),
    ],
)
def test_invalid_entry_metadata(client, field, value):
    item = item_operation()
    send(client, [item])
    data = {
        "item_id": item["record_id"],
        "quantity": "1",
        "unit": "u",
        "item_name": "Historical",
        "color": "#123456",
        "occurred_at": "2026-01-01T00:00:00+00:00",
        "timezone": "UTC",
        "note": "",
    }
    data[field] = value
    result = send(client, [item_operation(entity="entry", data=data)])
    assert result["results"][0]["status"] == "invalid"
    assert len(result["changes"]) == 1


def test_retry_after_process_restart_preserves_receipt_and_revision(tmp_path):
    from backend.app import create_app
    from backend.db import create_user

    app = create_app(tmp_path)
    create_user(app.state.db, "sample", "long synthetic password")
    first = TestClient(app)
    first.auth = ("sample", "long synthetic password")
    op = item_operation()
    receipt = send(first, [op])["results"]
    second = TestClient(create_app(tmp_path))
    second.auth = first.auth
    recovered = send(second, [op])
    assert recovered["results"] == receipt
    assert len(recovered["changes"]) == 1
    assert recovered["changes"][0]["version"] == 1


def test_concurrent_retries_commit_exactly_once(client):
    from concurrent.futures import ThreadPoolExecutor

    operation = item_operation()
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda _: send(client, [operation]), range(4)))
    assert all(response["results"] == responses[0]["results"] for response in responses)
    assert len(send(client, [])["changes"]) == 1


def test_cli_password_is_prompted_and_backup_is_restorable(
    tmp_path, monkeypatch, capsys
):
    import sys

    from backend.cli import main

    monkeypatch.setenv("CONFIG_DIR", str(tmp_path))
    monkeypatch.setattr(sys, "argv", ["intake", "create-user", "sample"])
    passwords = iter(["synthetic password long", "synthetic password long"])
    monkeypatch.setattr("getpass.getpass", lambda _: next(passwords))
    main()
    assert "Account created" in capsys.readouterr().out
    destination = tmp_path / "consistent.sqlite3"
    monkeypatch.setattr(sys, "argv", ["intake", "backup", str(destination)])
    main()
    with sqlite3.connect(destination) as db:
        assert db.execute("select username from users").fetchone()[0] == "sample"


def test_non_json_numeric_values_are_rejected_without_server_error(client):
    response = client.post(
        "/api/sync",
        content='{"operations":[{"id":NaN}],"cursor":0}',
        headers={"content-type": "application/json"},
    )
    assert response.status_code in {200, 422}
    if response.status_code == 200:
        assert response.json()["results"][0]["status"] == "invalid"


def test_failed_receipt_rolls_back_record_and_change(client):
    from backend.db import connect

    operation = item_operation()
    with connect(client.app.state.db) as db:
        db.execute(
            "CREATE TRIGGER fail_receipt BEFORE INSERT ON receipts BEGIN SELECT RAISE(ABORT,'simulated storage failure'); END"
        )
    failing = TestClient(client.app, raise_server_exceptions=False)
    failing.auth = client.auth
    assert (
        failing.post(
            "/api/sync", json={"operations": [operation], "cursor": 0}
        ).status_code
        == 500
    )
    with connect(client.app.state.db) as db:
        assert db.execute("SELECT COUNT(*) FROM records").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM changes").fetchone()[0] == 0
        db.execute("DROP TRIGGER fail_receipt")
    assert send(client, [operation])["results"][0]["status"] == "applied"


def test_chunked_body_limit_and_malformed_basic(client):
    response = client.post(
        "/api/sync",
        content=iter([b" " * (2 * 1024 * 1024), b" " * (2 * 1024 * 1024 + 1)]),
        headers={"content-type": "application/json"},
    )
    assert response.status_code == 413
    client.auth = None
    for value in ["Basic !!!", "Bearer anything", "Basic Og=="]:
        response = client.get("/api/me", headers={"authorization": value})
        assert response.status_code == 401


def test_malicious_cursor_does_not_escape_validation(client):
    response = client.post(
        "/api/sync",
        content='{"operations":[],"cursor":NaN}',
        headers={"content-type": "application/json"},
    )
    assert response.status_code == 422


@pytest.mark.parametrize(
    "authorization", [None, "Basic bWlzc2luZzp3cm9uZw==", "Basic invalid"]
)
def test_form_login_failure_does_not_challenge_browser(client, authorization):
    client.auth = None
    headers = {"X-Requested-With": "XMLHttpRequest"}
    if authorization:
        headers["Authorization"] = authorization
    response = client.get("/api/me", headers=headers)
    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid credentials"}
    assert "www-authenticate" not in response.headers


def test_native_basic_clients_keep_authentication_challenge(client):
    client.auth = None
    response = client.get("/api/me")
    assert response.status_code == 401
    assert response.headers["www-authenticate"].startswith("Basic ")
