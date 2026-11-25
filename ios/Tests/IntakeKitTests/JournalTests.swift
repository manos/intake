import XCTest

@testable import IntakeKit

final class JournalTests: XCTestCase {
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
