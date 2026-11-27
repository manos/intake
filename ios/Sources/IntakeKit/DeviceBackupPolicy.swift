import Foundation

/// All journal profiles and SQLite sidecars live under one directory. Apply
/// backup eligibility there so subsequent writes and new profiles inherit it.
public struct DeviceBackupPolicy {
  private let defaults: UserDefaults
  private let key = "storage.includeJournalInDeviceBackup"
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var enabled: Bool { defaults.object(forKey: key) as? Bool ?? true }

  public func apply(to directory: URL) throws {
    try apply(enabled, to: directory)
  }

  public func setEnabled(_ enabled: Bool, directory: URL) throws {
    try apply(enabled, to: directory)
    defaults.set(enabled, forKey: key)
  }

  private func apply(_ enabled: Bool, to directory: URL) throws {
    var folder = URL(fileURLWithPath: directory.path, isDirectory: true)
    guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw Problem.message("Journal storage is unavailable.")
    }
    // A read can reflect a parent directory's exclusion. Always set this
    // journal's own flag so its preference also holds if the parent changes.
    var values = URLResourceValues()
    values.isExcludedFromBackup = !enabled
    try folder.setResourceValues(values)
  }
}
