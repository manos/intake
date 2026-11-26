from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from backend.models import Day


def test_formatting_survives_sync_and_plain_client_zero_edit(tmp_path):
    from backend.app import create_app
    from backend.db import create_user

    app = create_app(tmp_path)
    create_user(app.state.db, "sample", "fixture")
    client = TestClient(app)
    client.auth = ("sample", "fixture")
    rid = str(uuid4())
    plain = {"date": "2026-11-26", "note": "🌿 Morning", "zero": False}
    rich = {**plain, "styles": [[3, 7, 3]]}

    def put(data, version):
        op = {
            "id": str(uuid4()),
            "record_id": rid,
            "entity": "day",
            "data": data,
            "base_version": version,
            "deleted": False,
        }
        result = client.post(
            "/api/sync", json={"operations": [op], "cursor": 0}
        ).json()["results"][0]
        assert result["status"] == "applied"
        return result["record"]["data"]

    assert put(rich, 0) == rich
    assert put({**plain, "zero": True}, 1) == {**rich, "zero": True}
    assert "styles" not in put({**plain, "styles": []}, 2)
    assert put(rich, 3) == rich
    assert "styles" not in put({**plain, "note": "edited"}, 4)


@pytest.mark.parametrize(
    "styles", [[[1, 1, 1]], [[2, 99, 1]], [[0, 2, 4]], [[0, 2, 1], [0, 2, 2]]]
)
def test_invalid_style_ranges(styles):
    with pytest.raises(ValidationError):
        Day(date="2026-11-26", note="🌿 Morning", zero=False, styles=styles)
