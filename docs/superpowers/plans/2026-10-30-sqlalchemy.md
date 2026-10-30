# SQLAlchemy Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline.

**Goal:** Replace direct sqlite3 application access with SQLAlchemy ORM while preserving existing SQLite databases and API behavior.
**Architecture:** Typed ORM mappings match the existing tables and serialized JSON text. Short synchronous sessions own each transaction; SQLite write sessions acquire BEGIN IMMEDIATE before reads to retain atomic bootstrap, throttling, receipt and revision behavior. SQLAlchemy owns engines/connections; SQLite's online backup API is accessed only through SQLAlchemy-managed driver connections because it has no ORM equivalent.
**Tech Stack:** Existing FastAPI, SQLAlchemy 2.x, SQLite default, uv-locked runtime dependencies.
**Spec:** `docs/design.md` storage contract and the user's SQLAlchemy request.

## Global Constraints
- Open `/config/intake.sqlite3` in place; no table rewrites, data conversion, account/session reset or frontend changes.
- Preserve atomic record/change/receipt commits and serialized writer admission.
- No raw application queries or sqlite3 imports in production; driver-specific setup/backup stays in the storage module.
- Sync API, registration, cookie/Basic auth, CLI and XLS behavior remain compatible.

## Review Focus
- Existing databases retain users, binary password hashes, sessions, revisions, receipts and monotonic change cursors.
- Concurrent duplicate operations apply once; different edits from one revision conflict.
- Failures roll back all writes; intentional failed-login throttle commits persist.
- Backup includes committed WAL data, refuses overwrite and retains private permissions.
- Engine/session lifecycle releases file handles and stays safe across FastAPI worker threads.

### Task 1: SQLAlchemy storage and API migration
- [ ] Add legacy-database, ORM-session, rollback/locking and backup compatibility regressions; observe failures.
- [ ] Define typed mappings and SQLAlchemy engine/session helpers; migrate API and CLI persistence to ORM expressions, maintaining behavior tests.
- [ ] Run backend/frontend suites, production build and lint; commit.

### Task 2: Review and rollout
- [ ] Independent read-only review; fix important findings with regressions.
- [ ] Validate against a synthetic legacy database through the real HTTP app and existing offline/browser scenarios.
- [ ] Push one PR, confirm checks, merge; back up live SQLite via existing CLI without exporting data, deploy localhost and Spark with full Ansible dry run/apply, verify source, health and data invariants, clean up worktree.
