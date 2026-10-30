"""ORM mappings compatible with the original SQLite schema."""

from sqlalchemy import ForeignKey, Index, Integer, LargeBinary, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(Text, primary_key=True)
    username: Mapped[str] = mapped_column(Text, unique=True)
    salt: Mapped[bytes] = mapped_column(LargeBinary)
    password: Mapped[bytes] = mapped_column(LargeBinary)
    settings: Mapped[str] = mapped_column(Text)


class Record(Base):
    __tablename__ = "records"
    user_id: Mapped[str] = mapped_column(Text, primary_key=True)
    id: Mapped[str] = mapped_column(Text, primary_key=True)
    entity: Mapped[str] = mapped_column(Text)
    version: Mapped[int]
    deleted: Mapped[int]
    data: Mapped[str] = mapped_column(Text)


class Change(Base):
    __tablename__ = "changes"
    __table_args__ = (
        Index("user_changes", "user_id", "seq"),
        {"sqlite_autoincrement": True},
    )
    seq: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[str] = mapped_column(Text)
    record: Mapped[str] = mapped_column(Text)


class Receipt(Base):
    __tablename__ = "receipts"
    user_id: Mapped[str] = mapped_column(Text, primary_key=True)
    id: Mapped[str] = mapped_column(Text, primary_key=True)
    payload: Mapped[str] = mapped_column(Text)
    result: Mapped[str] = mapped_column(Text)


class Throttle(Base):
    __tablename__ = "throttle"
    key: Mapped[str] = mapped_column(Text, primary_key=True)
    failures: Mapped[int]
    blocked_until: Mapped[float]


class BrowserSession(Base):
    __tablename__ = "sessions"
    token_hash: Mapped[str] = mapped_column(Text, primary_key=True)
    user_id: Mapped[str] = mapped_column(
        Text, ForeignKey("users.id", ondelete="CASCADE")
    )
    expires_at: Mapped[float]
