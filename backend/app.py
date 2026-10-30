"""Same-origin authenticated journal API."""

import base64
import binascii
import hashlib
import hmac
import io
import json
import os
import secrets
import time
from pathlib import Path
from urllib.parse import urlsplit

import xlwt
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import ValidationError
from sqlalchemy import delete, func, literal, or_, select, update
from sqlalchemy.exc import IntegrityError

from backend.db import connect, hash_password, initialize, insert_user
from backend.models import MODELS, Operation, Settings, Signup, Sync
from backend.tables import BrowserSession, Change, Receipt, Record, Throttle, User

MAX_BODY = 4 * 1024 * 1024
SESSION_SECONDS = 30 * 24 * 60 * 60
SESSION_COOKIE = "intake_session"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def record(row: Record):
    return {
        "id": row.id,
        "entity": row.entity,
        "version": row.version,
        "deleted": bool(row.deleted),
        "data": json.loads(row.data),
    }


def user_values(row: User | None):
    if row is None:
        return None
    return {
        "id": row.id,
        "username": row.username,
        "salt": row.salt,
        "password": row.password,
        "settings": row.settings,
    }


def create_app(config_dir=None):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.state.db = initialize(config_dir or os.environ.get("CONFIG_DIR", "/config"))
    allow_signup = os.environ.get("ALLOW_SIGNUP", "").lower() == "true"
    public_origin = os.environ.get("PUBLIC_ORIGIN", "").rstrip("/")
    if public_origin:
        parsed = urlsplit(public_origin)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or parsed.path
            or parsed.query
            or parsed.fragment
            or parsed.username
        ):
            raise ValueError(
                "PUBLIC_ORIGIN must be an HTTP(S) origin without path or credentials"
            )

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, error):
        return JSONResponse({"detail": "Invalid request payload"}, status_code=422)

    @app.middleware("http")
    async def protections(request, call_next):
        if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
            origin = request.headers.get("origin")
            if origin and origin not in {
                f"{request.url.scheme}://{request.url.netloc}",
                public_origin,
            }:
                return JSONResponse({"detail": "Origin rejected"}, status_code=403)
            if request.headers.get("sec-fetch-site") == "cross-site":
                return JSONResponse(
                    {"detail": "Cross-site request rejected"}, status_code=403
                )
        try:
            length = int(request.headers.get("content-length", "0") or 0)
            if length < 0:
                raise ValueError
        except ValueError:
            return JSONResponse({"detail": "Invalid content length"}, status_code=400)
        if length > MAX_BODY:
            return JSONResponse({"detail": "Request too large"}, status_code=413)
        # Read at the boundary so the JSON parser cannot turn an over-limit
        # receive exception into a generic 400. CachedRequest replays this body.
        body = bytearray()
        async for chunk in request.stream():
            if len(body) + len(chunk) > MAX_BODY:
                return JSONResponse({"detail": "Request too large"}, status_code=413)
            body.extend(chunk)
        request._body = bytes(body)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'"
        )
        if request.url.path.startswith("/api"):
            response.headers["Cache-Control"] = "private, no-store"
        return response

    def challenge(request):
        return (
            {}
            if request.headers.get("x-requested-with") == "XMLHttpRequest"
            else {"WWW-Authenticate": 'Basic realm="Intake", charset="UTF-8"'}
        )

    def bound_account(request, row):
        expected = request.headers.get("x-intake-account")
        if expected and expected != row["id"]:
            raise HTTPException(401, "Sign in to sync this account")
        return dict(row)

    def user(request: Request):
        username = password = ""
        authorization = request.headers.get("authorization", "")
        if not authorization:
            token = request.cookies.get(SESSION_COOKIE, "")
            if (
                token
                and len(token) <= 128
                and request.headers.get("x-requested-with") == "XMLHttpRequest"
            ):
                with connect(app.state.db) as db:
                    row = user_values(
                        db.scalar(
                            select(User)
                            .join(BrowserSession, User.id == BrowserSession.user_id)
                            .where(
                                BrowserSession.token_hash
                                == hashlib.sha256(token.encode()).hexdigest(),
                                BrowserSession.expires_at > time.time(),
                            )
                        )
                    )
                if row:
                    return bound_account(request, row)
            # A missing/expired random session is not a password attempt.
            raise HTTPException(401, "Invalid credentials", headers=challenge(request))
        try:
            scheme, encoded = authorization.split(" ", 1)
            if scheme.lower() == "basic" and len(encoded) <= 8192:
                username, password = (
                    base64.b64decode(encoded, validate=True)
                    .decode("utf-8")
                    .split(":", 1)
                )
        except (ValueError, UnicodeDecodeError, binascii.Error):
            pass
        host = request.client.host if request.client else "unknown"
        # Address bucket resists username rotation; persisted across process restart.
        key = hashlib.sha256(host.encode()).hexdigest()
        with connect(app.state.db, write=True) as db:
            bucket = db.get(Throttle, key)
            if bucket and bucket.blocked_until > time.time():
                raise HTTPException(
                    429,
                    "Too many login attempts",
                    headers={
                        "Retry-After": str(
                            max(1, int(bucket.blocked_until - time.time()))
                        )
                    },
                )
            row = user_values(db.scalar(select(User).where(User.username == username)))
            supplied = hash_password(
                password[:1024], row["salt"] if row else b"\0" * 32
            )
            if (
                not row
                or len(password) > 1024
                or not hmac.compare_digest(supplied, row["password"])
            ):
                failures = (bucket.failures if bucket else 0) + 1
                until = (
                    time.time() + min(900, 2 ** min(failures - 5, 10))
                    if failures >= 6
                    else 0
                )
                db.merge(Throttle(key=key, failures=failures, blocked_until=until))
                db.commit()
                # The app owns the sign-in form. A Basic challenge on its fetch
                # requests opens the browser's separate credentials dialog.
                raise HTTPException(
                    401,
                    "Invalid credentials",
                    headers=challenge(request),
                )
            db.execute(delete(Throttle).where(Throttle.key == key))
            return bound_account(request, row)

    authenticated_user = Depends(user)

    def browser_session(db, response, request, user_id):
        token = secrets.token_urlsafe(32)
        # Rotate this browser's session without ending sessions on other devices.
        previous = request.cookies.get(SESSION_COOKIE, "")
        db.execute(
            delete(BrowserSession).where(
                or_(
                    BrowserSession.expires_at <= time.time(),
                    BrowserSession.token_hash
                    == hashlib.sha256(previous.encode()).hexdigest(),
                )
            )
        )
        db.add(
            BrowserSession(
                token_hash=hashlib.sha256(token.encode()).hexdigest(),
                user_id=user_id,
                expires_at=time.time() + SESSION_SECONDS,
            )
        )
        response.set_cookie(
            SESSION_COOKIE,
            token,
            max_age=SESSION_SECONDS,
            path="/api",
            httponly=True,
            samesite="strict",
            secure=public_origin.startswith("https://")
            or request.url.scheme == "https",
        )

    @app.post("/api/session")
    def session(request: Request, response: Response, account=authenticated_user):
        if not request.headers.get("authorization"):
            raise HTTPException(401, "Password required", headers=challenge(request))
        with connect(app.state.db, write=True) as db:
            browser_session(db, response, request, account["id"])
        return me(account)

    @app.post("/api/logout", status_code=204)
    def logout(request: Request):
        if request.headers.get("x-requested-with") != "XMLHttpRequest":
            raise HTTPException(403, "App request required")
        token = request.cookies.get(SESSION_COOKIE, "")
        with connect(app.state.db, write=True) as db:
            db.execute(
                delete(BrowserSession).where(
                    BrowserSession.token_hash
                    == hashlib.sha256(token.encode()).hexdigest()
                )
            )
        response = Response(status_code=204)
        response.delete_cookie(SESSION_COOKIE, path="/api")
        return response

    @app.get("/health")
    def health():
        with connect(app.state.db) as db:
            db.execute(select(literal(1)))
        return {"status": "ok"}

    def signup_attempt(request: Request):
        # Independent persisted address namespace: account creation attempts must
        # neither consume nor clear the existing sign-in throttle.
        host = request.client.host if request.client else "unknown"
        key = "signup:" + hashlib.sha256(host.encode()).hexdigest()
        with connect(app.state.db, write=True) as db:
            # Read time after acquiring the lock: a concurrent request may have
            # written an unblocked timestamp while this request was waiting.
            now = time.time()
            bucket = db.get(Throttle, key)
            if bucket and bucket.blocked_until > now:
                raise HTTPException(
                    429,
                    "Too many registration attempts",
                    headers={
                        "Retry-After": str(max(1, int(bucket.blocked_until - now)))
                    },
                )
            # A quiet half hour starts a new allowance. Successful submissions
            # count too, so opt-in registration cannot create unbounded users.
            attempts = (
                bucket.failures if bucket and bucket.blocked_until > now - 1800 else 0
            )
            attempts += 1
            cooldown = min(900, 2 ** min(attempts - 5, 10)) if attempts >= 6 else 0
            db.merge(Throttle(key=key, failures=attempts, blocked_until=now + cooldown))

    registration_attempt = Depends(signup_attempt)

    @app.get("/api/registration")
    def registration():
        with connect(app.state.db) as db:
            first_run = db.scalar(select(User.id).limit(1)) is None
        return {"allowed": first_run or allow_signup, "first_run": first_run}

    @app.post("/api/signup", status_code=201)
    def signup(
        payload: Signup,
        request: Request,
        response: Response,
        attempt=registration_attempt,
    ):
        with connect(app.state.db, write=True) as db:
            # The lock covers bootstrap admission and insertion together. A
            # cached registration response never authorizes a later write.
            if not allow_signup and db.scalar(select(User.id).limit(1)):
                raise HTTPException(403, "Registration is closed")
            try:
                profile = insert_user(
                    db, payload.username, payload.password, payload.timezone
                )
                browser_session(db, response, request, profile["id"])
                return profile
            except IntegrityError:
                raise HTTPException(409, "Username is unavailable") from None

    @app.get("/api/me")
    def me(account=authenticated_user):
        return {
            "id": account["id"],
            "username": account["username"],
            "settings": json.loads(account["settings"]),
        }

    @app.put("/api/settings")
    def settings(payload: Settings, account=authenticated_user):
        data = payload.model_dump()
        with connect(app.state.db, write=True) as db:
            db.execute(
                update(User)
                .where(User.id == account["id"])
                .values(settings=canonical(data))
            )
        return data

    @app.post("/api/sync")
    def sync(payload: Sync, account=authenticated_user):
        uid = account["id"]
        results = []
        with connect(app.state.db) as db:
            latest = db.scalar(
                select(func.coalesce(func.max(Change.seq), 0)).where(
                    Change.user_id == uid
                )
            )
        if payload.cursor > latest:
            raise HTTPException(409, {"code": "cursor_reset", "cursor": 0})
        for raw in payload.operations:
            try:
                op = Operation.model_validate(raw)
                encoded = canonical(raw)
            except (ValueError, ValidationError):
                results.append(
                    {
                        "id": raw.get("id", "")
                        if isinstance(raw.get("id"), str)
                        else "",
                        "status": "invalid",
                        "message": "Invalid operation",
                    }
                )
                continue
            with connect(app.state.db, write=True) as db:
                receipt = db.get(Receipt, (uid, op.id))
                if receipt:
                    results.append(
                        json.loads(receipt.result)
                        if receipt.payload == encoded
                        else {
                            "id": op.id,
                            "status": "invalid",
                            "message": "Operation ID reused with different payload",
                        }
                    )
                    continue
                current = db.get(Record, (uid, op.record_id))
                result = {"id": op.id, "status": "invalid", "message": "Invalid record"}
                try:
                    if current and current.entity != op.entity:
                        raise ValueError("Record entity cannot change")
                    data = (
                        MODELS[op.entity].model_validate(op.data).model_dump()
                        if not op.deleted
                        else (json.loads(current.data) if current else {})
                    )
                    if op.deleted and not current:
                        raise ValueError("Cannot delete missing record")
                    if op.entity == "entry" and not op.deleted:
                        parent = db.get(Record, (uid, data["item_id"]))
                        if not parent or parent.entity != "item":
                            raise ValueError("Unknown item")
                    if (current.version if current else 0) != op.base_version:
                        result = {"id": op.id, "status": "conflict"}
                        if current:
                            result["record"] = record(current)
                    else:
                        saved = {
                            "id": op.record_id,
                            "entity": op.entity,
                            "version": op.base_version + 1,
                            "deleted": op.deleted,
                            "data": data,
                        }
                        if current is None:
                            current = Record(
                                user_id=uid, id=op.record_id, entity=op.entity
                            )
                            db.add(current)
                        current.version = saved["version"]
                        current.deleted = int(op.deleted)
                        current.data = canonical(data)
                        db.add(Change(user_id=uid, record=canonical(saved)))
                        result = {"id": op.id, "status": "applied", "record": saved}
                except (ValueError, ValidationError):
                    pass
                db.add(
                    Receipt(
                        user_id=uid, id=op.id, payload=encoded, result=canonical(result)
                    )
                )
                results.append(result)
        with connect(app.state.db) as db:
            rows = db.scalars(
                select(Change)
                .where(Change.user_id == uid, Change.seq > payload.cursor)
                .order_by(Change.seq)
                .limit(501)
            ).all()
            page = rows[:500]
            return {
                "results": results,
                "changes": [json.loads(row.record) for row in page],
                "cursor": page[-1].seq if page else payload.cursor,
                "has_more": len(rows) > 500,
            }

    @app.post("/api/export")
    def export(payload: dict, account=authenticated_user):
        if set(payload) != {"items", "entries", "days"}:
            raise HTTPException(422, "Snapshot needs items, entries and days")
        book = xlwt.Workbook()
        columns = {
            "items": [
                "id",
                "name",
                "unit",
                "amount",
                "color",
                "presets",
                "archived",
                "order",
            ],
            "entries": [
                "id",
                "item_id",
                "item_name",
                "quantity",
                "unit",
                "occurred_at",
                "timezone",
                "note",
                "color",
            ],
            "days": ["id", "date", "note", "zero"],
        }
        total = 0
        for plural, entity in [
            ("items", "item"),
            ("entries", "entry"),
            ("days", "day"),
        ]:
            rows = payload[plural]
            if not isinstance(rows, list) or len(rows) > 20000:
                raise HTTPException(422, "Snapshot list too large")
            total += len(rows)
            if total > 20000:
                raise HTTPException(422, "Snapshot too large")
            sheet = book.add_sheet(plural.title())
            for col, key in enumerate(columns[plural]):
                sheet.write(0, col, key)
            for index, raw in enumerate(rows, 1):
                if not isinstance(raw, dict):
                    raise HTTPException(422, "Invalid snapshot record")
                if raw.get("deleted") is True:
                    continue
                try:
                    data = (
                        MODELS[entity]
                        .model_validate(
                            raw.get("data", {k: v for k, v in raw.items() if k != "id"})
                        )
                        .model_dump()
                    )
                except (ValueError, ValidationError):
                    raise HTTPException(422, "Invalid snapshot record")
                data["id"] = str(raw.get("id", ""))[:100]
                for col, key in enumerate(columns[plural]):
                    value = data[key]
                    if isinstance(value, list):
                        value = canonical(value)
                    # xlwt writes strings as literal text, including leading =,+,-,@.
                    sheet.write(index, col, value)
        output = io.BytesIO()
        book.save(output)
        return Response(
            output.getvalue(),
            media_type="application/vnd.ms-excel",
            headers={"Content-Disposition": 'attachment; filename="intake.xls"'},
        )

    static = Path(os.environ.get("STATIC_DIR", "frontend/dist")).resolve()

    @app.get("/{requested:path}")
    def shell(requested: str):
        if requested == "api" or requested.startswith("api/"):
            raise HTTPException(404)
        candidate = (static / requested).resolve()
        if not candidate.is_relative_to(static):
            raise HTTPException(404)
        if candidate.is_file():
            return FileResponse(candidate)
        if (static / "index.html").exists():
            return FileResponse(
                static / "index.html", headers={"Cache-Control": "no-cache"}
            )
        raise HTTPException(404)

    return app


app = create_app()
