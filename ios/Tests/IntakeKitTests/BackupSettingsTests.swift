import Foundation
import XCTest

@testable import IntakeKit

final class BackupSettingsTests: XCTestCase {
  func testDeviceBackupPreferenceAppliesToTheJournalDirectoryAndSurvivesReopening() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let name = "intake.test." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: root)
    }
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let journal = try Journal(file: root.appendingPathComponent("intake.sqlite3"))
    let row = Record(
      .day, id: JournalTime.dayID("2026-11-27"),
      data: ["date": .string("2026-11-27"), "note": .string("Offline entry"), "zero": .bool(false)])
    try journal.put(row)
    let policy = DeviceBackupPolicy(defaults: defaults)
    XCTAssertTrue(policy.enabled)
    func excluded(_ folder: URL) throws -> Bool {
      var url = folder
      url.removeAllCachedResourceValues()
      return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        == true
    }
    try policy.setEnabled(false, directory: root)
    XCTAssertTrue(try excluded(root))
    let reopened = DeviceBackupPolicy(defaults: defaults)
    XCTAssertFalse(reopened.enabled)
    let replacement = root.appendingPathComponent("replacement", isDirectory: true)
    try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
    try reopened.apply(to: replacement)
    XCTAssertTrue(try excluded(replacement))
    try reopened.setEnabled(true, directory: root)
    XCTAssertFalse(try excluded(root))
    XCTAssertTrue(policy.enabled)
    XCTAssertEqual(try journal.read().records[row.id], row)
    XCTAssertThrowsError(
      try policy.setEnabled(false, directory: root.appendingPathComponent("missing")))
    XCTAssertTrue(policy.enabled)
  }

  func testKeepLocalCopyIsPersistentPerJournalAndTogglingDoesNotDeleteData() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let journal = try Journal(file: file, profile: "one")
    try journal.link(
      Binding(origin: "https://example.test", account: "one", username: "sample"), remote: [],
      cursor: 0, settings: Settings())
    let row = Record(
      .day, id: JournalTime.dayID("2026-11-27"),
      data: ["date": .string("2026-11-27"), "note": .string("Pending entry"), "zero": .bool(false)])
    try journal.put(row)
    let before = try journal.read()
    XCTAssertTrue(before.keepLocalCopy)
    try journal.setKeepLocalCopy(false)
    let reopened = try Journal(file: file, profile: "one").read()
    XCTAssertFalse(reopened.keepLocalCopy)
    XCTAssertEqual(reopened.records, before.records)
    XCTAssertEqual(reopened.pending, before.pending)
    XCTAssertTrue(try Journal(file: file, profile: "two").read().keepLocalCopy)
  }
}
