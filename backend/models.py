"""Strict wire-format validation; decimal quantities retain their source representation."""

from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


def positive(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise ValueError("Expected positive decimal")  # noqa: TRY004 - Pydantic validators require ValueError
    try:
        number = Decimal(str(value))
        if (
            not number.is_finite()
            or number <= 0
            or number > Decimal("1e12")
            or len(str(value)) > 64
        ):
            raise ValueError("Quantity out of range")
    except InvalidOperation as error:
        raise ValueError("Invalid decimal") from error
    return value


def valid_timezone(value):
    try:
        ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError("Unknown timezone")
    return value


USERNAME_PATTERN = r"[A-Za-z0-9_.-]{1,64}"


class Signup(Strict):
    username: str = Field(min_length=1, max_length=64, pattern=rf"^{USERNAME_PATTERN}$")
    password: str = Field(min_length=12, max_length=1024, repr=False)
    timezone: str = Field(max_length=100)
    _timezone = field_validator("timezone")(valid_timezone)


class Settings(Strict):
    timezone: str = Field(max_length=100)
    day_start: int = Field(ge=0, le=23)
    _timezone = field_validator("timezone")(valid_timezone)


class Item(Strict):
    name: str = Field(min_length=1, max_length=200)
    color: str = Field(pattern=r"^#[0-9a-fA-F]{6}$")
    unit: str = Field(min_length=1, max_length=64)
    amount: str | int | float
    presets: list[str | int | float] = Field(max_length=30)
    archived: bool
    order: int = Field(ge=-1000000, le=1000000)
    _amount = field_validator("amount")(positive)

    @field_validator("presets")
    @classmethod
    def valid_presets(cls, values):
        return [positive(v) for v in values]


class Entry(Strict):
    item_id: str
    quantity: str | int | float
    unit: str = Field(min_length=1, max_length=64)
    item_name: str = Field(min_length=1, max_length=200)
    color: str = Field(pattern=r"^#[0-9a-fA-F]{6}$")
    occurred_at: str = Field(max_length=64)
    timezone: str = Field(max_length=100)
    note: str = Field(max_length=10000)
    _quantity = field_validator("quantity")(positive)
    _timezone = field_validator("timezone")(valid_timezone)

    @field_validator("item_id")
    @classmethod
    def uuid(cls, value):
        UUID(value)
        return value

    @field_validator("occurred_at")
    @classmethod
    def timestamp(cls, value):
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError("Timestamp must include timezone offset")
        return value


class Day(Strict):
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    note: str = Field(max_length=10000)
    zero: bool

    @field_validator("date")
    @classmethod
    def valid_date(cls, value):
        date.fromisoformat(value)
        return value


class Sync(Strict):
    operations: list[dict] = Field(max_length=500)
    cursor: int = Field(ge=0, le=9223372036854775807)


class Operation(Strict):
    id: str
    entity: Literal["item", "entry", "day"]
    record_id: str
    base_version: int = Field(ge=0, le=9223372036854775806)
    data: dict
    deleted: bool

    @field_validator("id", "record_id")
    @classmethod
    def uuid(cls, value):
        UUID(value)
        return value


MODELS = {"item": Item, "entry": Entry, "day": Day}
