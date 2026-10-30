"""Storage adoption must not rewrite or reset an existing journal."""

import hashlib
import json
import sqlite3
import time
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from backend.db import backup, connect, create_user, hash_password, initialize
from backend.tables import Change, User


def test_connect_is_a_sqlalchemy_session_and_closes_transactions(tmp_path):
    path = initialize(tmp_path)
    with connect(path) as session:
        assert isinstance(session, Session)
    assert not session.in_transaction()


def test_orm_transaction_rolls_back_and_subsequent_write_succeeds(tmp_path):
    path = initialize(tmp_path)
    with pytest.raises(RuntimeError), connect(path, write=True) as session:
        session.add(
            User(
                id="failed",
                username="failed",
                salt=b"salt",
                password=b"hash",
                settings="{}",
            )
        )
        session.flush()
        raise RuntimeError("interrupted transaction")
    with connect(path) as session:
        assert session.get(User, "failed") is None
    create_user(path, "next", "synthetic storage password")


def test_old_session_and_receipt_survive_orm_adoption(tmp_path):
    from backend.app import canonical, create_app

    path = tmp_path / "intake.sqlite3"
    uid, item, operation_id = (str(uuid4()) for _ in range(3))
    salt = b"s" * 32
    password = "synthetic migration password"
    token = "synthetic-existing-session"
    data = {
        "name": "Existing",
        "color": "#123abc",
        "unit": "tablet",
        "amount": "1",
        "presets": [],
        "archived": False,
        "order": 0,
    }
    operation = {
        "id": operation_id,
        "entity": "item",
        "record_id": item,
        "base_version": 0,
        "data": data,
        "deleted": False,
    }
    saved = {"id": item, "entity": "item", "version": 1, "deleted": False, "data": data}
    receipt = {"id": operation_id, "status": "applied", "record": saved}
    with sqlite3.connect(path) as db:
        db.executescript(Path(__file__).with_name("legacy_schema.sql").read_text())
        db.execute(
            "INSERT INTO users VALUES(?,?,?,?,?)",
            (
                uid,
                "existing",
                salt,
                hash_password(password, salt),
                json.dumps({"timezone": "UTC", "day_start": 0}),
            ),
        )
        db.execute(
            "INSERT INTO records VALUES(?,?,?,?,?,?)",
            (uid, item, "item", 1, 0, canonical(data)),
        )
        db.execute(
            "INSERT INTO changes(seq,user_id,record) VALUES(?,?,?)",
            (901, uid, canonical(saved)),
        )
        db.execute(
            "INSERT INTO receipts VALUES(?,?,?,?)",
            (uid, operation_id, canonical(operation), canonical(receipt)),
        )
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (hashlib.sha256(token.encode()).hexdigest(), uid, time.time() + 3600),
        )
    client = TestClient(
        create_app(tmp_path), headers={"X-Requested-With": "XMLHttpRequest"}
    )
    client.cookies.set("intake_session", token, path="/api")
    assert client.get("/api/me").json()["id"] == uid
    response = client.post(
        "/api/sync", json={"operations": [operation], "cursor": 0}
    ).json()
    assert response["results"] == [receipt]
    assert response["changes"] == [saved]
    assert response["cursor"] == 901
    client.cookies.clear()
    assert client.get("/api/me", auth=("existing", password)).status_code == 200
    with connect(path, write=True) as session:
        change = Change(user_id=uid, record=canonical(saved))
        session.add(change)
        session.flush()
        assert change.seq == 902


def test_backup_reads_committed_wal_snapshot_while_writer_is_active(tmp_path):
    path = initialize(tmp_path)
    create_user(path, "committed", "synthetic storage password")
    with sqlite3.connect(path) as writer:
        writer.execute("BEGIN IMMEDIATE")
        writer.execute(
            "INSERT INTO users VALUES(?,?,?,?,?)",
            ("pending", "pending", b"salt", b"hash", "{}"),
        )
        target = tmp_path / "while-writing.sqlite3"
        backup(path, target)
        with sqlite3.connect(target) as restored:
            assert restored.execute("SELECT username FROM users").fetchall() == [
                ("committed",)
            ]


def test_adopts_legacy_schema_without_changing_existing_rows(tmp_path):
    # Build the previous release's schema independently of the new ORM.
    path = tmp_path / "intake.sqlite3"
    with sqlite3.connect(path) as db:
        db.executescript(Path(__file__).with_name("legacy_schema.sql").read_text())
        db.execute(
            "INSERT INTO users VALUES(?,?,?,?,?)",
            (
                "old-user",
                "legacy",
                b"s" * 32,
                b"h" * 64,
                '{"timezone":"UTC","day_start":0}',
            ),
        )
        db.execute(
            "INSERT INTO records VALUES(?,?,?,?,?,?)",
            ("old-user", "old-item", "item", 7, 0, '{"name":"legacy snapshot"}'),
        )
        db.execute(
            "INSERT INTO changes(seq,user_id,record) VALUES(?,?,?)",
            (901, "old-user", '{"version":7}'),
        )
        db.execute(
            "INSERT INTO receipts VALUES(?,?,?,?)",
            ("old-user", "old-op", '{"payload":true}', '{"status":"applied"}'),
        )
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            ("token-hash", "old-user", time.time() + 3600),
        )
        db.execute(
            "INSERT INTO throttle VALUES(?,?,?)", ("existing", 8, time.time() + 60)
        )
        before = {
            table: db.execute(f"SELECT * FROM {table}").fetchall()
            for table in (
                "users",
                "records",
                "changes",
                "receipts",
                "sessions",
                "throttle",
            )
        }
    assert initialize(tmp_path) == path
    with sqlite3.connect(path) as db:
        after = {
            table: db.execute(f"SELECT * FROM {table}").fetchall() for table in before
        }
    assert after == before
    target = tmp_path / "backup.sqlite3"
    backup(path, target)
    with sqlite3.connect(target) as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert {
            table: db.execute(f"SELECT * FROM {table}").fetchall() for table in before
        } == before
    assert path.stat().st_mode & 0o777 == 0o600
    assert target.stat().st_mode & 0o777 == 0o600
