# Intake

A quiet, private journal for medicines and anything else you choose to track. One tap records an exact time. Review entries and daily totals, even offline, and optionally sync with your own server.

Intake starts empty. Add your own names, colors, quantities and units. No accounts, medicines, goals or categories are preconfigured.

## Native iPhone app

Open `ios/Intake.xcodeproj` in Xcode, select **Intake** and build for iOS 17 or later. For a device install, use your development signing team. The app opens to an empty local journal without a server account. Its SQLite journal lives in Application Support and is eligible for ordinary iCloud **device backup** when enabled for Intake. This is full-device recovery, not live iCloud sync. Device-only server credentials do not migrate.

On **Today**, tap an item to log its default amount, or tap a dosage button for a preset. The first presets that fit appear beside the item. The **…** menu always has the full list.

Daily totals appear just below **Edit day note or zero day**, before the first entry. Connection status and sync feedback scroll with the list. Choose an app accent in **Settings → Appearance → Accent color**; individual item colors stay as you set them.

**Existing user?** Open **Settings → Sync → Connect to server** and enter your Intake credentials. A fresh phone downloads your existing journal and settings. If you already logged things on the phone, choose **Sync this journal** to merge both histories. Only conflicting records need a choice. Browser edits that never synced can be exported as JSON and imported on the phone. Record IDs and original entry times survive migration.

Once connected, pull down and release on **Today** to sync. A spinner follows the sync, then **Success!** appears briefly. **Sync failed** means the sync did not finish; the status below the badge gives details. A local-only journal shows no connection badge or sign-in prompt.

The native client requires an HTTPS origin with a hostname-matching, publicly verifiable certificate. Set `PUBLIC_ORIGIN` to exactly the HTTPS origin your phone uses. Three automatic renewal options:

- **[Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)** (private tailnet): with tailnet HTTPS enabled, run `tailscale serve --bg http://127.0.0.1:8000` on the Compose host. Enter the full HTTPS name it prints and connect the iPhone to the same tailnet. Serve obtains the certificate; no public port or Funnel needed.
- **[Nginx Proxy Manager](https://nginxproxymanager.com/)**: create a Proxy Host for your DNS name pointing to the app's reachable private port, select a Let's Encrypt certificate and enable Force SSL. A proxy container's `localhost` means that container, not Intake. Use DNS validation for private-only ingress.
- **[cert-manager](https://cert-manager.io/docs/usage/ingress/)**: use a production Let's Encrypt ACME issuer on your existing Kubernetes Ingress. Set `spec.tls.hosts` to the public certificate name and a `secretName` for renewal. DNS-01 allows the service itself to stay private.

Connected users can delete their own server account from Settings, including when registration is closed. Confirm the named server and account and choose whether to retain a local-only copy. A server must be online for deletion. Older releases still support sign-in and migration; upgrade the backend to use account deletion or native signup.

After restoring a self-hosted database from backup, use **Settings → Sync → Compare entire server history**. This compares both journals even when the restored server's change counter has caught up. Conflicting quantities and notes stay available for review.

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

FastAPI serves the built frontend and API from one origin. SQLAlchemy manages users, versioned records, idempotency receipts and the change log, using SQLite under `/config` by default. Existing SQLite files are opened in place without conversion. The client uses an account-scoped IndexedDB database and transactional outbox. No cloud service, CDN or analytics is involved.

Read [design](docs/design.md) and [security](SECURITY.md) before contributing. Tests cover retries, conflicts, account isolation, timestamp boundaries and spreadsheet output. Use synthetic fixtures only. MIT licensed; see [LICENSE](LICENSE).
