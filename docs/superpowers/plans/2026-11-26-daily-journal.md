# Daily Journal and Server Aliases Implementation Plan

> **For agentic workers:** Use the executing-plans skill to implement the approved work inline.

**Goal:** Make any valid HTTP(S) server address usable and provide one editable, formatted journal page per day.

**Architecture:** Discover an address without credentials before establishing a session. Keep a temporary destination separate from the permanent connection address and bind tokens to the authenticated origin. Add optional formatting spans to existing day records; unformatted records retain their wire shape.

**Tech stack:** SwiftUI, UIKit TextKit, Foundation URLSession, FastAPI, and the existing SQLite sync contract.

**Spec:** Approved daily notebook design: Today | Journal | History | Settings; paged days, date jump, large editor with bold and body/heading styles, compact intake by item and unit. Entry notes remain plain text.

## Global constraints
- Preserve iOS 17 support, offline access, account isolation, and existing journal IDs.
- No fixed hostname, private deployment configuration, or HTTPS-only gate.
- Use the existing worktree without staging local signing changes.

## Review focus
- Looping redirects, temporary redirects mixed with permanent redirects, and failed authentication.
- A cached token must not follow a redirect to a new origin.
- Unicode text and ranges, plain-text clients, and JSON round trips.
- Paging over DST, month, and year boundaries, including empty days.
- Saving the same date from Today, History, or Journal must edit the same record.

## Tasks
- [x] `Server.swift`, `JournalModel.swift`, `SettingsView.swift`, Info.plist: test address parsing and anonymous redirect discovery; use the verified endpoint for auth and save the permanent address on successful link.
- [x] `backend/models.py`, `backend/app.py`, `frontend/src/import.ts`, `IntakeKit`: validate optional UTF-16 formatting runs while preserving plain day notes and snapshot compatibility. Test valid and malformed formatting on each side.
- [x] Native Journal tab and shared day editor: show adjacent civil days and a date picker; render notes, compact totals, and empty/zero states from the local display index. Edit bold and heading text inline with TextKit.
- [ ] Update setup and journaling docs, build the iPhone app, run targeted tests, push to main, and verify the deployed server.
