"""Durable local storage and administrative operations."""

import hashlib
import json
import os
import re
from contextlib import contextmanager
from functools import lru_cache
from pathlib import Path
from uuid import uuid4

from sqlalchemy import URL, create_engine, event
from sqlalchemy.orm import Session
from sqlalchemy.pool import NullPool

from backend.models import USERNAME_PATTERN
from backend.tables import Base, User


@lru_cache(maxsize=32)
def engine_for(path):
    engine = create_engine(
        URL.create("sqlite+pysqlite", database=str(Path(path).resolve())),
        connect_args={"timeout": 30, "check_same_thread": False},
        poolclass=NullPool,
        hide_parameters=True,
    )

    @event.listens_for(engine, "connect")
    def configure(connection, _):
        connection.isolation_level = None
        cursor = connection.cursor()
        try:
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.execute("PRAGMA journal_mode=WAL")
        finally:
            cursor.close()

    @event.listens_for(engine, "begin")
    def begin(connection):
        connection.exec_driver_sql(
            "BEGIN IMMEDIATE"
            if connection.get_execution_options().get("sqlite_write")
            else "BEGIN"
        )

    return engine


@contextmanager
def connect(path, *, write=False):
    """One short unit of work; acquire the writer lock before reading mutable state."""
    with (
        engine_for(path).connect().execution_options(sqlite_write=write) as connection,
        Session(connection, expire_on_commit=False) as session,
        session.begin(),
    ):
        if write:
            # Session.begin() is lazy: acquire BEGIN IMMEDIATE before callers
            # sample time or make admission decisions, not at their first query.
            session.connection()
        yield session


def initialize(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / "intake.sqlite3"
    Base.metadata.create_all(engine_for(path))
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
    with connect(path, write=True) as db:
        insert_user(db, username, password, "UTC")


def insert_user(db, username, password, timezone):
    """Insert validated account values in the caller's transaction."""
    salt = os.urandom(32)
    user_id = str(uuid4())
    settings = {"timezone": timezone, "day_start": 0}
    db.add(
        User(
            id=user_id,
            username=username,
            salt=salt,
            password=hash_password(password, salt),
            settings=json.dumps(settings),
        )
    )
    db.flush()
    return {"id": user_id, "username": username, "settings": settings}


def backup(path, target):
    target = Path(target)
    # Refuse accidental overwrite, including the active database.
    descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        # SQLAlchemy has no cross-dialect online-backup operation. Use SQLite's
        # consistent backup through its SQLAlchemy-managed driver connections.
        source = engine_for(path).raw_connection()
        try:
            destination = engine_for(target).raw_connection()
            try:
                source.driver_connection.backup(destination.driver_connection)
            finally:
                destination.close()
        finally:
            source.close()
    except Exception:
        target.unlink(missing_ok=True)
        raise
