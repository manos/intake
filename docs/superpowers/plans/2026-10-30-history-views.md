# History Views Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. Steps use checkbox syntax for tracking.

**Goal:** Add weekly charts, exact-time timelines, per-item detail and a calendar to History.

**Architecture:** Derive history entirely from the existing account's materialized local journal. A pure history module groups entries by configured timezone/day boundary and preserves snapshot units; a Svelte History component owns filters and views, with callbacks into the existing entry/day editor. No backend, storage schema or dependencies change.

**Tech Stack:** Existing Svelte 5, TypeScript, CSS and Vitest; native chart controls.

**Spec:** `docs/design.md` History views section and the approved chat proposal.

## Global Constraints
- Dark purple, concise functional copy, no defaults or decorative asterisks.
- Today totals stay visible; all views include pending local records and work offline.
- Never combine different medicines' quantities or different snapshot units.
- Unlogged days differ from explicitly confirmed zero days.
- Exact timestamps/notes remain accessible; no time buckets.

## Review Focus
- DST and non-midnight day boundaries must group correctly and retain repeated local times.
- Archived/renamed items and historical unit changes must remain visible without combining units.
- Empty/filter-only days must never become inferred zero days.
- Narrow screens and dense timestamps must retain reachable controls and avoid page overflow.
- Account switches must reset history selection and never introduce cross-account state.

### Task 1: Local history calculations
**Files:** create `frontend/src/history.ts`, `frontend/src/history.test.ts`; update `docs/design.md`.
**Interfaces:** `historyItems(records)` returns current/historical item options; `historyDays(records, settings, from, to, itemId?)` returns ordered days with all/matching entries and explicit state; `quantityTotals(entries)` groups by snapshot unit; `historySummary(days)` returns entries/days/median-gap; `timePosition(timestamp, settings)` returns fractional configured-day position; calendar/week/date helpers operate on YYYY-MM-DD strings.
- [ ] Write tests for week/month/year navigation, range validation, timezone/DST grouping, zero-vs-unlogged, pending/deleted records, archived/orphan items, unit separation, median gaps and exact time positions.
- [ ] Run `npm test --prefix frontend` and observe failures for missing functions.
- [ ] Implement pure helpers, using existing `dayKey` and no new dependencies.
- [ ] Run the frontend suite, compare expected values, commit.

### Task 2: History screens and delivery
**Files:** create `frontend/src/History.svelte`; update `frontend/src/App.svelte`, `frontend/src/style.css`, `README.md`.
**Interfaces:** History receives records/profile/today and `onentry(Row)`/`onday(date)` callbacks; it consumes Task 1 helpers and never writes the journal. Key component by account ID.
- [ ] Add shared medicine/date filters and Week/Timeline/By item/Calendar controls. Default to Monday-based current week; calendar switches to a full month; previous/next navigation preserves active view semantics.
- [ ] Add per-item weekly count/quantity charts, exact-time dots with collision lanes, selectable item summaries/details and monthly calendar with visible state/legend. Totals separate units; tapping entries opens existing editor and days open daily history.
- [ ] Run frontend tests/build and backend tests. Run isolated synthetic mobile/desktop browser checks for all views, filters/navigation, historical units, timezone boundary, offline pending edits, exact-entry editing, zero/unlogged distinction, account reset and no overflow.
- [ ] Commit; request one independent whole-branch review, address important findings with regression checks.
- [ ] Push one PR, confirm checks, merge and rebuild localhost. Dry-run the full Spark playbook, inspect drift, apply via Ansible, verify live source and health, then clean up the worktree.
