"""Browser sessions survive reloads without persisting a Basic password."""

import hashlib
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update

from backend.db import connect, create_user
from backend.tables import BrowserSession

PASSWORD = "synthetic session password"
HEADERS = {"X-Requested-With": "XMLHttpRequest"}


def client_for(tmp_path, monkeypatch, secure=False):
    from backend.app import create_app

    origin = "https://intake.example" if secure else "http://testserver"
    monkeypatch.setenv("PUBLIC_ORIGIN", origin)
    app = create_app(tmp_path)
    create_user(app.state.db, "sample", PASSWORD)
    return TestClient(app, base_url=origin, headers=HEADERS)


def login(client):
    response = client.post("/api/session", auth=("sample", PASSWORD))
    assert response.status_code == 200
    return response


def test_session_survives_server_restart_and_syncs_without_basic(tmp_path, monkeypatch):
    from backend.app import create_app

    client = client_for(tmp_path, monkeypatch)
    profile = login(client).json()
    restarted = TestClient(create_app(tmp_path), headers=HEADERS)
    restarted.cookies.update(client.cookies)
    assert restarted.get("/api/me").json() == profile
    item = {
        "id": str(uuid4()),
        "entity": "item",
        "record_id": str(uuid4()),
        "base_version": 0,
        "deleted": False,
        "data": {
            "name": "Example",
            "color": "#123abc",
            "unit": "unit",
            "amount": 1,
            "presets": [],
            "archived": False,
            "order": 0,
        },
    }
    response = restarted.post(
        "/api/sync",
        json={"operations": [item], "cursor": 0},
        headers={"X-Intake-Account": profile["id"]},
    )
    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "applied"


@pytest.mark.parametrize("secure", [False, True])
def test_cookie_security_and_only_hash_stored(tmp_path, monkeypatch, secure):
    client = client_for(tmp_path, monkeypatch, secure)
    response = login(client)
    cookie = response.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie
    assert "path=/api" in cookie and "max-age=2592000" in cookie
    assert ("; secure" in cookie) is secure
    token = client.cookies["intake_session"]
    assert (
        len(token) >= 43
        and token not in response.text
        and PASSWORD not in response.text
    )
    with connect(client.app.state.db) as db:
        row = db.scalar(select(BrowserSession))
        assert row.token_hash == hashlib.sha256(token.encode()).hexdigest()
        assert token not in (row.token_hash, row.user_id)


def test_expired_revoked_and_forged_sessions_cannot_sync(tmp_path, monkeypatch):
    client = client_for(tmp_path, monkeypatch)
    login(client)
    token = client.cookies["intake_session"]
    assert client.post("/api/logout").status_code == 204
    assert "intake_session" not in client.cookies
    client.cookies.set("intake_session", token, path="/api")
    assert client.get("/api/me").status_code == 401
    client.cookies.clear()
    login(client)
    with connect(client.app.state.db, write=True) as db:
        db.execute(update(BrowserSession).values(expires_at=0))
    assert client.get("/api/me").status_code == 401
    client.cookies.set("intake_session", "forged", path="/api")
    assert client.get("/api/me").status_code == 401


def test_cookie_cannot_sync_cached_account_after_another_tab_signs_in(
    tmp_path, monkeypatch
):
    client = client_for(tmp_path, monkeypatch)
    first = login(client).json()
    create_user(client.app.state.db, "other", PASSWORD)
    second = client.post("/api/session", auth=("other", PASSWORD)).json()
    assert second["id"] != first["id"]
    response = client.post(
        "/api/sync",
        json={"operations": [], "cursor": 0},
        headers={"X-Intake-Account": first["id"]},
    )
    assert response.status_code == 401
    assert "www-authenticate" not in response.headers


def test_cookie_requires_app_header_and_cross_site_requests_are_rejected(
    tmp_path, monkeypatch
):
    client = client_for(tmp_path, monkeypatch)
    login(client)
    client.headers.clear()
    assert client.get("/api/me").status_code == 401
    response = client.post(
        "/api/logout", headers={**HEADERS, "Origin": "https://attacker.example"}
    )
    assert response.status_code == 403
    assert client.get("/api/me", headers=HEADERS).status_code == 200
    assert client.post("/api/session", auth=("sample", "wrong")).status_code == 401


def test_signup_also_establishes_browser_session(tmp_path, monkeypatch):
    from backend.app import create_app

    monkeypatch.setenv("ALLOW_SIGNUP", "false")
    client = TestClient(create_app(tmp_path), headers=HEADERS)
    response = client.post(
        "/api/signup", json={"username": "new", "password": PASSWORD, "timezone": "UTC"}
    )
    assert response.status_code == 201
    assert client.get("/api/me").json() == response.json()
