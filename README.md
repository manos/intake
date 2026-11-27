# Intake

A quiet, private journal for medicines and anything else you choose to track. One tap records an exact time. Review entries and daily totals, even offline, and optionally sync with your own server.

Intake starts empty. Add your own names, colors, quantities and units. No accounts, medicines, goals or categories are preconfigured.

## Native iPhone app

Open `ios/Intake.xcodeproj` in Xcode, select **Intake** and build for iOS 17 or later. For a device install, use your development signing team. The app opens to an empty local journal without a server account. Its SQLite journal lives in Application Support and is eligible for ordinary iCloud **device backup** when enabled for Intake. This is full-device recovery, not live iCloud sync. Device-only server credentials do not migrate.

On **Today**, tap an item to log its default amount, or tap a dosage button for a preset. The first presets that fit appear beside the item. The **…** menu always has the full list.

Daily totals appear just below **Edit Daily Journal**, before the first intake entry. Last-taken times, entries, and totals follow the current journal day, using your chosen timezone and day-start hour. Opening Today or pulling down updates that day, including offline.

Use **Settings → Items → Sort items** to drag items into your preferred order, then tap **Done**. Today, Journal summaries, and History item groups use that same order; individual logs stay chronological. Changes sync with your account. In **Settings → Appearance**, choose the accent, background, row background, text color, or Home Screen icon. **Reset colors** restores the default palette without changing your item colors.

**Journal** opens to the current journal day. Swipe between pages, use the arrows, or tap the date to jump. Each page shows the Daily Journal above a compact intake summary, with separate totals for each item and unit. Tap **Write Daily Journal** or **Edit Daily Journal** to open the editor. In the **Aa** formatting menu, choose **Bold**, **Body**, or **Heading** for selected text or the next text you type. Tap **Save** to keep the page offline and sync it when connected. Today and History open the same Daily Journal. Individual intake notes remain plain text.

**Existing user?** Open **Settings → Sync → Connect to server** and enter your Intake credentials. A fresh phone downloads your existing journal and settings. If you already logged things on the phone, choose **Sync this journal** to merge both histories. Only conflicting records need a choice. Browser edits that never synced can be exported as JSON and imported on the phone. Record IDs and original entry times survive migration.

Pull down and release on **Today** to reload the local journal and sync when the connection is enabled. The upper-right cloud is green when connected, or gray and slashed when disconnected. Automatic sync never inserts a status row. Connection details are in **Settings → Sync**; signed-out and local-only journals show no cloud.

Tap the green cloud to disconnect this journal on this iPhone without signing out. Local changes wait on the device, even after reopening the app. Tap the slashed cloud to reconnect and sync them. If the server is temporarily unreachable, the same button retries the connection.

The native client accepts HTTP or HTTPS server addresses, including arbitrary LAN names and IP addresses with optional ports. A bare hostname starts with HTTP. During setup the app follows redirects before sending credentials. After sign-in and connection, it remembers permanent redirects (301/308); temporary destinations do not replace the address you entered. For example, a LAN alias can redirect to a private HTTPS server with a managed certificate. Set `PUBLIC_ORIGIN` to the external origin your server uses. Three options for automatic certificate renewal:

- **[Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)** (private tailnet): with tailnet HTTPS enabled, run `tailscale serve --bg http://127.0.0.1:8000` on the Compose host. Enter the full HTTPS name it prints and connect the iPhone to the same tailnet. Serve obtains the certificate; no public port or Funnel needed.
- **[Nginx Proxy Manager](https://nginxproxymanager.com/)**: create a Proxy Host for your DNS name pointing to the app's reachable private port, select a Let's Encrypt certificate and enable Force SSL. A proxy container's `localhost` means that container, not Intake. Use DNS validation for private-only ingress.
- **[cert-manager](https://cert-manager.io/docs/usage/ingress/)**: use a production Let's Encrypt ACME issuer on your existing Kubernetes Ingress. Set `spec.tls.hosts` to the public certificate name and a `secretName` for renewal. DNS-01 allows the service itself to stay private.

**Settings → Sync** also holds the account and backup controls. Both toggles default to on:

- **Keep a local copy** retains this journal on the iPhone after you confirm **Delete server account**. Turning the toggle off does not erase anything by itself. Sign-out and pausing sync preserve pending changes either way.
- **Back up to iCloud** makes all Intake journals on this iPhone eligible for the next iOS device backup. Turning it off excludes the journal directory from device backups. iOS controls backup timing and the device-wide iCloud settings.

Connected users can delete their own server account even when registration is closed. A server must be online for deletion. Older releases still support sign-in and migration; upgrade the backend to use account deletion or native signup.

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
- Write in the Daily Journal without adding an intake. Explicitly confirm a zero-intake day; an empty day is otherwise unrecorded.
- Explore History through weekly count/amount charts, an exact-time timeline, per-item summaries and a monthly calendar. Filter by dates or item, navigate previous periods, and tap a day or entry for its full journal and notes. Archived items and historical units remain available; quantities in different units stay separate.
- Archive medicines while retaining history. Imported data is previewed and validated before saving.
- Export or restore an Intake **JSON backup** offline. For a spreadsheet, connect to the backend and export an Excel 97–2003 **`.xls`** workbook, including locally pending entries.

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
