from uuid import uuid4

from sqlalchemy import select

from backend.db import connect, create_user
from backend.tables import BrowserSession, Change, Receipt, Record, User
from backend.tests.test_sessions import PASSWORD, client_for, login


def test_delete_bound_account_removes_journal_and_revokes_all_sessions(
    tmp_path, monkeypatch
):
    client = client_for(tmp_path, monkeypatch)
    create_user(client.app.state.db, "other", PASSWORD)
    first = login(client).json()["id"]
    old_token = client.cookies["intake_session"]
    client.cookies.clear()
    login(client)
    assert client.get("/api/capabilities").json()["account_deletion"]
    data = {
        "name": "Test",
        "unit": "u",
        "amount": "0.1",
        "presets": [],
        "color": "#123456",
        "archived": False,
        "order": 0,
    }
    op = {
        "entity": "item",
        "id": str(uuid4()),
        "record_id": str(uuid4()),
        "data": data,
        "deleted": False,
        "base_version": 0,
    }
    assert (
        client.post("/api/sync", json={"operations": [op], "cursor": 0}).json()[
            "results"
        ][0]["status"]
        == "applied"
    )
    assert (
        client.delete("/api/account", headers={"X-Intake-Account": "wrong"}).status_code
        == 401
    )
    assert client.delete("/api/account").status_code == 400
    assert (
        client.delete("/api/account", headers={"X-Intake-Account": first}).status_code
        == 204
    )
    client.cookies.set("intake_session", old_token, path="/api")
    assert client.get("/api/me").status_code == 401
    with connect(client.app.state.db) as db:
        assert db.get(User, first) is None
        for model in (Record, Receipt, Change, BrowserSession):
            assert db.scalar(select(model).where(model.user_id == first)) is None
    assert client.get("/api/me", auth=("other", PASSWORD)).status_code == 200
