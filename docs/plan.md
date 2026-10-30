# Intake Implementation Plan
Goal: complete the approved Intake design in docs/design.md.
Architecture: Svelte/TypeScript PWA with IndexedDB outbox; FastAPI sync backend and SQLite; Compose with operator-managed networking.
Global constraints: empty catalog, MIT, real .xls, no private fixtures, no credentials persisted in browser storage, all user data isolated.
Review focus: lost sync response; concurrent local edit and pull; identity changes; malformed imports/timezones; database storage failure.

1. Backend (backend/): first failing behavior tests for auth, per-user isolation, idempotent operations, revision conflicts, validation, XLS signatures; then implement API, database, CLI. pytest must pass.
2. Frontend (frontend/): first failing tests for day boundaries, durable local logs and outbox ordering; implement IndexedDB/sync and full responsive Svelte experience; test/build.
3. Delivery (Dockerfile, compose.yaml, README, LICENSE, CI): package and run container with persistent config, create synthetic local smoke user, test frontend/API and export, check restart persistence; no seed data shipped.
4. Independent review of auth, sync, UI and import/export; resolve findings and re-run tests. Commit and push public MIT source, open preview, report exact verification limits.
