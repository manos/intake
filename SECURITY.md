# Security

Intake is designed for a trusted personal device accessing a privately hosted server. Keep it on loopback or a private network. Use HTTPS for Basic authentication outside loopback and for the offline service worker on another device.

There are no initial users or medicines. The first account can be created in the app while the database is empty. Registration then closes unless the operator enables `ALLOW_SIGNUP=true`; the interactive operator command can also create additional accounts. Complete first-run setup before making the service accessible to other people. The backend stores password hashes. The interface holds HTTP Basic credentials in memory only. Authenticated API responses are not service-worker cached. Each user's locally saved journal and pending queue are isolated by server origin and immutable user ID.

Offline access means the device retains readable journal data after the server becomes unavailable, including after credentials are changed or revoked. Device access is therefore access to that local copy. Use the operating system's screen lock and disk encryption. Clearing browser data removes pending entries: synchronize or export a JSON backup first. Requesting persistent browser storage reduces eviction risk but cannot prevent deliberate clearing. Do not use private browsing for your journal.

Counts include this device's pending edits. Offline counts cannot include unseen entries from other devices. Conflicting edits require resolution; sync never silently changes a recorded quantity. Backup the server and export unsynced client changes before restoring an older database. After a server restore, use a new browser origin/profile or clear the old local copy only after exporting pending data, then import that backup; stale cursors may refer to the previous database history.

The app provides records, not clinical recommendations or dose scheduling. No medicine names, categories, alcohol quantities, or limits are supplied automatically.

Report vulnerabilities privately using the repository's Security Advisory feature. Include a synthetic reproduction; never include your real journal, passwords, or exported health data.

## Dependency review

The initial release's Python runtime dependency audit reported no known vulnerabilities. The npm audit reported two low-severity development-tool advisories in `@sveltejs/vite-plugin-svelte` and its `deepmerge` dependency, with no upstream fix available. This dependency processes the trusted build configuration and is not included in the runtime container. These advisories remain open; a clean backend audit does not mean the build-tool advisory has been remediated. Container OS packages were not vulnerability-scanned as part of this release.
