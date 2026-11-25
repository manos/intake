import XCTest

@testable import IntakeKit

final class JournalTests: XCTestCase {
  let binding = Binding(origin: "https://example.com", account: "one", username: "sample")
  func testFailedSyncStaysVisibleUntilTheWholeSyncSucceeds() {
    var presence = ServerPresence()
    presence.report(server: "one", generation: presence.generation, reachable: true)
    presence.finishedSync(server: "one", succeeded: false)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .syncFailed)
    presence.networkChanged(offline: false)
    presence.report(server: "one", generation: presence.generation, reachable: true)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .syncFailed)
    XCTAssertEqual(presence.badge(server: "two", signedIn: true), .checking)
    XCTAssertNil(presence.badge(server: nil, signedIn: false))
    presence.finishedSync(server: "one", succeeded: true)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .connected)
  }
  func testBadgeRequiresAResponseFromTheCurrentServerOnTheCurrentNetwork() {
    var presence = ServerPresence()
    XCTAssertNil(presence.badge(server: nil, signedIn: false))
    let old = presence.generation
    presence.report(server: "one", generation: old, reachable: true)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .connected)
    XCTAssertEqual(presence.badge(server: "two", signedIn: true), .checking)
    presence.networkChanged(offline: true)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .offline)
    presence.networkChanged(offline: false)
    presence.report(server: "one", generation: old, reachable: true)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .checking)
    presence.report(server: "one", generation: presence.generation, reachable: false)
    XCTAssertEqual(presence.badge(server: "one", signedIn: true), .offline)
    XCTAssertEqual(presence.badge(server: "one", signedIn: false), .signIn)
  }
  func testLoggingSyncedNumericAndStringPresetsKeepsExactTimeAndAmount() throws {
    let journal = try Journal()
    let settings = Settings(timezone: "America/New_York")
    var serverItem = try sample()[0]
    serverItem.version = 1
    try journal.link(binding, remote: [serverItem], cursor: 1, settings: settings)
    let item = try XCTUnwrap(journal.read().visible(.item).first)
    let time = Date(timeIntervalSince1970: 1_793_500_214.125)
    let presets = try XCTUnwrap(item.data["presets"]?.values)
    for amount in [nil] + presets.map({ Optional($0.text) }) {
      try journal.put(item.entry(settings: settings, amount: amount, at: time))
    }
    let queued = try journal.batch()
    XCTAssertEqual(queued.map { $0.data["quantity"]?.text }, ["0.125", "1", "0.125"])
    for op in queued {
      XCTAssertEqual(op.data["occurred_at"]?.text, "2026-11-01T02:30:14.125Z")
      XCTAssertEqual(op.data["timezone"]?.text, "America/New_York")
      XCTAssertEqual(op.data["item_id"]?.text, item.id)
    }
  }

  func testEntryValidationNamesOnlyTheFailingField() throws {
    let entry = try sample()[1]
    let cases: [(String, Value, String)] = [
      ("quantity", .string("0"), "Amount"),
      ("occurred_at", .string("2026-11-01T01:30:00"), "Timestamp"),
      ("timezone", .string("Not/AZone"), "Time zone"), ("item_id", .string("invalid"), "Item ID"),
      ("color", .string("blue"), "Color"), ("unit", .string(""), "Unit"),
      ("item_name", .string(""), "Item name"), ("note", .number(1), "Note"),
    ]
    for (key, value, label) in cases {
      var bad = entry
      bad.data[key] = value
      XCTAssertThrowsError(try Transfer.validate(bad)) {
        XCTAssertTrue(
          $0.localizedDescription.hasPrefix(label), "\(key): \($0.localizedDescription)")
      }
    }
  }
  func testPreviewBoundToOneJournalCannotCommitIntoAnother() throws {
    let a = try Journal(profile: "a")
    let b = try Journal(profile: "b")
    let data = try sample()
    let original = try a.scope()
    XCTAssertThrowsError(try b.applyImport(data, expectedScope: original))
    try a.link(binding, remote: [], cursor: 0, settings: Settings())
    XCTAssertThrowsError(try a.applyImport(data, expectedScope: original))
    XCTAssertTrue(try b.read().records.isEmpty)
    XCTAssertTrue(try a.read().pending.isEmpty)
  }
  func testMergeIntoCachedProfilePreservesPendingAndUniqueDoses() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let local = try Journal(file: url, profile: "local")
    let dest = try Journal(file: url, profile: "destination")
    let rows = try sample()
    try dest.link(binding, remote: [rows[0]], cursor: 4, settings: Settings())
    var other = rows[1]
    other.id = UUID().uuidString
    try dest.put(other)
    try local.applyImport(rows)
    try dest.absorb(local: local.profile)
    try dest.absorb(local: local.profile)
    XCTAssertEqual(try dest.read().visible(.entry).count, 2)
    XCTAssertEqual(try dest.batch().count, 2)
  }
  func testDuplicateServerDatesResolvedWithoutThirdID() throws {
    let j = try Journal()
    var note = Record(
      .day, data: ["date": .string("2026-11-01"), "note": .string("local"), "zero": .bool(false)])
    try j.put(note)
    note.id = UUID().uuidString
    note.version = 1
    note.data["note"] = .string("web one")
    var second = note
    second.id = UUID().uuidString
    second.data["note"] = .string("web two")
    try j.link(binding, remote: [note, second], cursor: 4, settings: Settings())
    let candidates = try XCTUnwrap(j.read().competingDays["2026-11-01"])
    XCTAssertEqual(candidates.count, 3)
    let local = try XCTUnwrap(candidates.first { $0.text("note") == "local" })
    try j.resolveDay("2026-11-01", using: local)
    XCTAssertEqual(try j.read().visible(.day).map { $0.text("note") }, ["local"])
    XCTAssertTrue(try j.batch().allSatisfy { [note.id, second.id].contains($0.record_id) })
  }
  func testInterruptedAccountDeletionNeverSchedulesRemoteWorkAndKeepsUserChoice() throws {
    for keep in [true, false] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: url) }
      let j = try Journal(file: url)
      let rows = try sample()
      try j.link(binding, remote: [rows[0]], cursor: 1, settings: Settings())
      try j.put(rows[1])
      try j.deletionAttempt(keepLocal: keep)
      let restored = try Journal(file: url)
      XCTAssertEqual(try restored.read().deletionChoice, keep)
      try restored.disconnectAfterDeletion(keepLocal: keep)
      XCTAssertNil(try restored.read().binding)
      XCTAssertNil(try restored.read().deletionChoice)
      XCTAssertEqual(try restored.read().visible(.entry).count, keep ? 1 : 0)
      XCTAssertTrue(try restored.batch().isEmpty)
    }
  }
  func testCooldownSurvivesLocalEditsAndEndsAtRetryAfter() throws {
    let now = Date()
    let until = now.addingTimeInterval(60)
    let j = try Journal()
    try j.postpone(until: until)
    try j.put(sample()[0])
    XCTAssertFalse(try j.read().maySync(at: now.addingTimeInterval(59)))
    XCTAssertTrue(try j.read().maySync(at: until))
  }
  func testRollbackKeepsAcknowledgedAndUnresolvedQuantities() throws {
    var rows = try sample()
    rows[0].version = 1
    rows[1].version = 2
    let j = try Journal()
    try j.link(binding, remote: rows, cursor: 3, settings: Settings())
    var earlier = rows[1]
    earlier.version = 1
    earlier.data["quantity"] = .string("3")
    for _ in 0..<2 {
      try j.link(
        binding, remote: [rows[0], earlier], cursor: 2, settings: Settings(), recovering: true)
      XCTAssertEqual(try j.read().records[earlier.id]?.text("quantity"), "0.125")
      XCTAssertEqual(try j.read().conflicts[earlier.id]?.remote?.text("quantity"), "3")
      XCTAssertTrue(try j.batch().isEmpty)
    }
  }
  func testAcknowledgedPurgeSurvivesRollbackAndImport() throws {
    let rows = try sample()
    let j = try Journal()
    var tomb = rows[0]
    tomb.data = [:]
    tomb.deleted = true
    tomb.version = 2
    try j.link(binding, remote: [tomb], cursor: 4, settings: Settings())
    try j.link(binding, remote: rows, cursor: 2, settings: Settings(), recovering: true)
    try j.applyImport(rows)
    XCTAssertTrue(try j.read().visible(.item).isEmpty)
    XCTAssertTrue(try j.read().visible(.entry).isEmpty)
    XCTAssertEqual(try j.read().purges, [tomb.id])
  }
  func testStaleEditorCannotReplaceNewerQuantity() throws {
    var rows = try sample()
    rows[1].version = 1
    let j = try Journal()
    try j.link(binding, remote: rows, cursor: 2, settings: Settings())
    var web = rows[1]
    web.version = 2
    web.data["quantity"] = .string("7")
    try j.accept(Page(results: [], changes: [web], cursor: 3, has_more: false))
    var draft = rows[1]
    draft.data["note"] = .string("Edited while web synced")
    XCTAssertThrowsError(try j.put(draft))
    XCTAssertEqual(try j.read().records[web.id]?.text("quantity"), "7")
  }
  func testInvalidResponseDoesNotEraseKnownServerRow() throws {
    var item = try sample()[0]
    item.version = 1
    let j = try Journal()
    try j.link(binding, remote: [item], cursor: 1, settings: Settings())
    var draft = item
    draft.data["name"] = .string("Alternate")
    try j.put(draft)
    let op = try XCTUnwrap(j.batch().first)
    try j.accept(
      Page(
        results: [SyncResult(id: op.id, status: "invalid", record: nil, message: "Invalid")],
        changes: [], cursor: 1, has_more: false))
    try j.resolve(item.id, keepLocal: false)
    XCTAssertEqual(try j.read().records[item.id], item)
  }
  func testMergeComparisonPreservesAllWireDigits() throws {
    var a = try sample()[0]
    var b = a
    let prefix = "0." + String(repeating: "1", count: 42)
    a.data["amount"] = .string(prefix + "1")
    b.data["amount"] = .string(prefix + "2")
    XCTAssertFalse(a.equivalent(b))
    a.data["amount"] = .string("0.100")
    b.data["amount"] = .string("1e-1")
    XCTAssertTrue(a.equivalent(b))
  }
  func sample() throws -> [Record] {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "web", withExtension: "json", subdirectory: "Fixtures"))
    return try Transfer.decode(Data(contentsOf: url), csv: false)
  }

  func testLocalRestoreAndDuplicateImport() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let initial = try Journal(file: file)
    try initial.applyImport(sample())
    let reopened = try Journal(file: file)
    try reopened.applyImport(sample())
    let state = try reopened.read()
    XCTAssertNil(state.binding)
    XCTAssertEqual(state.visible(.entry).count, 1)
    XCTAssertEqual(state.visible(.entry).first?.text("occurred_at"), "2026-11-01T01:30:14-05:00")
    XCTAssertTrue(state.pending.isEmpty)
    XCTAssertEqual(try Transfer.decode(Transfer.export(state), csv: false).count, 2)
  }

  func testFirstLinkMergesWithoutInventingDuplicateDoses() throws {
    let journal = try Journal()
    let local = try sample()
    try journal.applyImport(local)
    var remote = local[1]
    remote.data["quantity"] = .string("2")
    remote.version = 1
    var item = local[0]
    item.version = 2
    let binding = Binding(origin: "https://intake.example", account: "one", username: "sam")
    try journal.link(binding, remote: [item, remote], cursor: 32, settings: Settings())
    let s = try journal.read()
    XCTAssertEqual(s.conflicts.count, 1)
    XCTAssertEqual(s.visible(.entry).first?.text("quantity"), "0.125")
    XCTAssertEqual(s.cursor, 32)
    XCTAssertTrue(try journal.batch().isEmpty)
    try journal.resolve(local[1].id, keepLocal: true)
    let first = try journal.batch()
    XCTAssertEqual(first, try journal.batch())
    XCTAssertEqual(first.first?.base_version, 1)
  }

  func testRepeatedHourMatchesWebDayAndStableIdentity() throws {
    let entry = try sample()[1]
    let instant = try XCTUnwrap(JournalTime.instant(entry.text("occurred_at")))
    let day = JournalTime.day(
      instant, settings: Settings(timezone: "America/New_York", day_start: 4))
    XCTAssertEqual(day, "2026-10-31")
    XCTAssertEqual(JournalTime.dayID(day), "dc262c92-b17d-52f1-bddc-82ee5df8071b")
  }

  func testUndoBeforeFirstSendDoesNotDeleteUnknownServerRecord() throws {
    let j = try Journal()
    let rows = try sample()
    try j.link(
      .init(origin: "https://example.com", account: "one", username: "sample"), remote: [],
      cursor: 0, settings: Settings())
    try j.put(rows[0])
    try j.put(rows[1])
    var removed = rows[1]
    removed.deleted = true
    try j.put(removed)
    XCTAssertFalse(try j.read().pending.contains { $0.record_id == removed.id })
    try j.put(rows[1])
    XCTAssertTrue(try j.read().pending.contains { $0.record_id == removed.id })
  }

  func testImportConflictRetainsBothChoicesAndCommitsUnrelatedRows() throws {
    let j = try Journal()
    let data = try sample()
    try j.applyImport(data)
    var alternative = data[1]
    alternative.data["note"] = .string("Revised in browser")
    var other = data[1]
    other.id = UUID().uuidString.lowercased()
    try j.applyImport([alternative, other])
    XCTAssertEqual(try j.read().visible(.entry).count, 2)
    XCTAssertEqual(try j.read().importConflicts[alternative.id]?.text("note"), "Revised in browser")
    try j.resolveImport(alternative.id, useImported: true)
    XCTAssertEqual(try j.read().records[alternative.id]?.text("note"), "Revised in browser")
  }

  func testInterveningPullDoesNotRebaseAnUnsentEditOverAnotherDevice() throws {
    let j = try Journal()
    var original = try sample()[0]
    original.version = 1
    try j.link(
      .init(origin: "https://example.com", account: "x", username: "sample"), remote: [original],
      cursor: 1, settings: Settings())
    var local = original
    local.data["name"] = .string("Local")
    try j.put(local)
    var server = original
    server.version = 2
    server.data["name"] = .string("Remote")
    try j.accept(Page(results: [], changes: [server], cursor: 2, has_more: false))
    XCTAssertEqual(
      try j.batch().first?.base_version, 1,
      "The pending edit must conflict rather than overwrite the unseen remote edit.")
  }
}
