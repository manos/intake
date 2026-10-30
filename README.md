# Intake

A quiet, private journal for medicines and anything else you choose to track. One tap records an exact time. Today's totals stay visible, even while browsing history. Works offline after the first visit and syncs with your own server when it becomes reachable.

Intake starts empty. Add your own names, colors, quantities and units. No accounts, medicines, goals or categories are preconfigured.

## Run locally

Requires Docker with Compose.

```sh
git clone https://github.com/manos/intake.git
cd intake
docker compose build
docker compose up -d
```

Open **http://localhost:8000** and create your account in the app. First launch offers account creation; registration closes automatically after that account exists. Set `ALLOW_SIGNUP=true` to permit additional people to register, or use the operator command below. The default configuration publishes only on loopback. First login needs the server; subsequent offline visits reopen your local journal. Passwords are not saved by the app, so reconnecting after reopening may require signing in again. A sign-in error never removes pending entries.

The named `intake_config` volume is mounted at `/config` and survives container recreation. The server runs as UID/GID 10001. For a bind mount, replace the volume with `./config:/config` and give UID 10001 ownership of that directory before starting. Use local disk rather than a network filesystem for SQLite. Do not commit your config directory or exported journal.

To create additional accounts without opening registration:

```sh
docker compose exec app python -m backend.cli create-user yourname
```

This prompts for a password without displaying it. Each account has its own medicines and journal.

## Offline access and reverse proxies

Open the app once while connected before using it offline. Install it using your browser's Add to Home Screen option. Keep the same origin on subsequent visits, because browser storage belongs to an origin. Offline reopening on another device requires a trusted HTTPS origin; localhost works for development. Sync while the app is open or reopened is supported; closed-app background sync depends on the browser.

When using your own reverse proxy, set `PUBLIC_ORIGIN` to the exact external origin, such as `https://intake.example.test`. The app recognizes this origin for request protection without trusting arbitrary forwarded headers.

## Everyday use

- Create a medicine with a name, color, unit, default amount, and optional amount presets.
- Tap its logging button to save now. Enter a note first if desired. Change the time to backdate. Edit or undo afterward.
- Configure your timezone and when your day begins. Timestamps are retained exactly; grouping into a day never rounds them.
- Add daily notes without adding an intake. Explicitly confirm a zero-intake day; an empty day is otherwise unrecorded.
- Explore History through weekly count/amount charts, an exact-time timeline, per-item summaries and a monthly calendar. Filter by dates or item, navigate previous periods, and tap a day or entry for its full journal and notes. Archived items and historical units remain available; quantities in different units stay separate.
- Archive medicines while retaining history. Imported data is previewed and validated before saving.
- Export a real Excel 97–2003 **`.xls`** workbook, including locally pending entries. XLS generation requires the backend. JSON backup is available offline; JSON/CSV imports support migration.

A local save is acknowledged only after its IndexedDB transaction succeeds. The visible pending count shows entries still waiting for the server. Independent devices cannot know each other's offline entries. If both edit the same record, Intake preserves the local change and asks which version to keep.

Sign-in lasts 30 days on this browser. Intake restores the session after reopening and syncs automatically when the server returns. Passwords are never saved. Sign out from the account dialog to end the session; pending entries stay on the device until you sign in again.

## Backup and restore

```sh
docker compose exec app python -m backend.cli backup /config/backup.sqlite3
docker compose cp app:/config/backup.sqlite3 ./backup.sqlite3
```

This takes a consistent SQLite backup while the server runs. Also export a JSON backup on devices with pending changes; those entries aren't in the server backup yet. To restore, stop the app, preserve the existing volume, replace the database from a verified backup with correct file ownership, then start again. See [security and offline storage](SECURITY.md) for device/cache and restore considerations.

## Development

Python 3.12+ and Node 24. Dependencies are locked in `uv.lock` and `frontend/package-lock.json`.

```sh
uv sync --locked --extra dev
cd frontend && npm ci && npm test && npm run build
cd ..
uv run pytest
CONFIG_DIR=/tmp/intake-dev uv run python -m backend.cli create-user yourname
CONFIG_DIR=/tmp/intake-dev uv run uvicorn backend.app:app --port 8000
```

FastAPI serves the built frontend and API from one origin. SQLite stores users, versioned records, idempotency receipts and a change log. The client uses an account-scoped IndexedDB database and transactional outbox. No cloud service, CDN or analytics is involved.

Read [design](docs/design.md) and [security](SECURITY.md) before contributing. Tests cover retries, conflicts, account isolation, timestamp boundaries and spreadsheet output. Use synthetic fixtures only. MIT licensed; see [LICENSE](LICENSE).
