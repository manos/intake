"""Registration is opt-in after a serialized first-account bootstrap."""

from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient

PASSWORD = "synthetic registration password"


def make_client(tmp_path, monkeypatch, allow=False):
    from backend.app import create_app

    monkeypatch.setenv("ALLOW_SIGNUP", "true" if allow else "false")
    return TestClient(create_app(tmp_path))


def signup(client, username="sample", **changes):
    data = {"username": username, "password": PASSWORD, "timezone": "America/Denver"}
    data.update(changes)
    return client.post("/api/signup", json=data)


def test_first_account_signup_and_signin(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch)
    assert client.get("/api/registration").json() == {
        "allowed": True,
        "first_run": True,
    }
    response = signup(client)
    assert response.status_code == 201
    profile = response.json()
    assert set(profile) == {"id", "username", "settings"}
    assert profile["settings"] == {"timezone": "America/Denver", "day_start": 0}
    assert PASSWORD not in response.text
    assert client.get("/api/registration").json() == {
        "allowed": False,
        "first_run": False,
    }
    assert signup(client, "other").status_code == 403
    assert client.get("/api/me").status_code == 401
    client.auth = ("sample", PASSWORD)
    assert client.get("/api/me").json() == profile


def test_opt_in_signup_and_duplicate_does_not_replace_password(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch, allow=True)
    assert signup(client).status_code == 201
    assert signup(client, "other").status_code == 201
    assert client.get("/api/registration").json() == {
        "allowed": True,
        "first_run": False,
    }
    response = signup(client, password="different synthetic password")
    assert response.status_code == 409
    client.auth = ("sample", PASSWORD)
    assert client.get("/api/me").status_code == 200


def test_parallel_bootstrap_creates_only_one(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch)
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(
            pool.map(lambda name: signup(client, name), ["first", "second"])
        )
    assert sorted(response.status_code for response in responses) == [201, 403]
    from backend.db import connect

    with connect(client.app.state.db) as db:
        assert db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1


@pytest.mark.parametrize(
    "changes",
    [
        {"username": ""},
        {"username": "invalid name"},
        {"username": "a" * 65},
        {"password": "short"},
        {"password": "x" * 1025},
        {"password": 12},
        {"timezone": "../UTC"},
        {"timezone": "Invalid/Zone"},
        {"unexpected": True},
    ],
)
def test_invalid_signup_is_sanitized(tmp_path, monkeypatch, changes):
    client = make_client(tmp_path, monkeypatch)
    response = signup(client, **changes)
    assert response.status_code == 422
    assert response.json() == {"detail": "Invalid request payload"}
    assert client.get("/api/registration").json()["first_run"] is True


def test_signup_throttle_persists_and_is_separate_from_login(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch, allow=True)
    assert signup(client).status_code == 201
    for _ in range(5):
        assert signup(client, password="short").status_code == 422
    from backend.app import create_app

    restarted = TestClient(create_app(tmp_path))
    response = signup(restarted, "other")
    assert response.status_code == 429
    assert int(response.headers["retry-after"]) >= 1
    restarted.auth = ("sample", PASSWORD)
    assert restarted.get("/api/me").status_code == 200
