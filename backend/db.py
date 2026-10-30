"""Durable local storage and administrative operations."""

import hashlib
import json
import os
import re
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

from backend.models import USERNAME_PATTERN


@contextmanager
def connect(path):
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    try:
        with db:
            yield db
    finally:
        db.close()


def initialize(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / "intake.sqlite3"
    with connect(path) as db:
        db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, salt BLOB NOT NULL, password BLOB NOT NULL, settings TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS records(user_id TEXT NOT NULL, id TEXT NOT NULL, entity TEXT NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY(user_id,id));
        CREATE TABLE IF NOT EXISTS changes(seq INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, record TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS user_changes ON changes(user_id,seq);
        CREATE TABLE IF NOT EXISTS receipts(user_id TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(user_id,id));
        CREATE TABLE IF NOT EXISTS throttle(key TEXT PRIMARY KEY, failures INTEGER NOT NULL, blocked_until REAL NOT NULL);
        """)
    os.chmod(path, 0o600)
    return path


def hash_password(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)


def create_user(path, username, password):
    if not re.fullmatch(USERNAME_PATTERN, username):
        raise ValueError(
            "Username must be 1–64 letters, numbers, dots, underscores or hyphens"
        )
    if not 12 <= len(password) <= 1024:
        raise ValueError("Password must contain 12–1024 characters")
    with connect(path) as db:
        insert_user(db, username, password, "UTC")


def insert_user(db, username, password, timezone):
    """Insert validated account values in the caller's transaction."""
    salt = os.urandom(32)
    user_id = str(uuid4())
    settings = {"timezone": timezone, "day_start": 0}
    db.execute(
        "INSERT INTO users VALUES(?,?,?,?,?)",
        (user_id, username, salt, hash_password(password, salt), json.dumps(settings)),
    )
    return {"id": user_id, "username": username, "settings": settings}


def backup(path, target):
    target = Path(target)
    # Refuse accidental overwrite, including the active database.
    descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        with connect(path) as source, sqlite3.connect(target) as destination:
            source.backup(destination)
    except Exception:
        target.unlink(missing_ok=True)
        raise
