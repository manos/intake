import Foundation
import XCTest

@testable import IntakeKit

final class BackupSettingsTests: XCTestCase {
  func testJournalRetainsItsOwnOptOutWhenParentBecomesEligibleAgain() throws {
    let fm = FileManager.default
    let support = try fm.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var parent = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let child = parent.appendingPathComponent("Journal", isDirectory: true)
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    let name = UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer {
      try? fm.removeItem(at: parent)
      defaults.removePersistentDomain(forName: name)
    }
    var inherited = URLResourceValues()
    inherited.isExcludedFromBackup = true
    try parent.setResourceValues(inherited)
    try DeviceBackupPolicy(defaults: defaults).setEnabled(false, directory: child)
    inherited.isExcludedFromBackup = false
    try parent.setResourceValues(inherited)
    let fresh = URL(fileURLWithPath: child.path, isDirectory: true)
    XCTAssertEqual(
      try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }
  func testDeviceBackupPreferenceAppliesToTheJournalDirectoryAndSurvivesReopening() throws {
    let fm = FileManager.default
    let support = try fm.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let fixture = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = fixture.appendingPathComponent("Journal", isDirectory: true)
    let name = "intake.test." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer {
      defaults.removePersistentDomain(forName: name)
      try? fm.removeItem(at: fixture)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let journal = try Journal(file: root.appendingPathComponent("intake.sqlite3"))
    let row = Record(
      .day, id: JournalTime.dayID("2026-11-27"),
      data: ["date": .string("2026-11-27"), "note": .string("Offline entry"), "zero": .bool(false)])
    try journal.put(row)
    let policy = DeviceBackupPolicy(defaults: defaults)
    XCTAssertTrue(policy.enabled)
    func excluded(_ folder: URL) throws -> Bool {
      let url = URL(fileURLWithPath: folder.path, isDirectory: true)
      return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        == true
    }
    let reference = fixture.appendingPathComponent("Reference", isDirectory: true)
    try fm.createDirectory(at: reference, withIntermediateDirectories: true)
    try policy.setEnabled(false, directory: root)
    XCTAssertTrue(try excluded(root))
    let reopened = DeviceBackupPolicy(defaults: defaults)
    XCTAssertFalse(reopened.enabled)
    let replacement = fixture.appendingPathComponent("replacement", isDirectory: true)
    try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
    try reopened.apply(to: replacement)
    XCTAssertTrue(try excluded(replacement))
    try reopened.setEnabled(true, directory: root)
    // Enabling backup removes our exclusion, not an OS-level exclusion
    // inherited from the test host. Compare with an untouched sibling.
    XCTAssertEqual(try excluded(root), try excluded(reference))
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
