"""Keep all test storage temporary, including the default ASGI app."""

import pytest


@pytest.fixture(autouse=True)
def temporary_default_config(tmp_path, monkeypatch):
    monkeypatch.setenv("CONFIG_DIR", str(tmp_path / "default"))
