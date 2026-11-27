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
    var folder = directory
    folder.removeAllCachedResourceValues()
    let existing = try folder.resourceValues(forKeys: [.isDirectoryKey, .isExcludedFromBackupKey])
    guard existing.isDirectory == true else {
      throw Problem.message("Journal storage is unavailable.")
    }
    if (existing.isExcludedFromBackup ?? false) != !enabled {
      var values = URLResourceValues()
      values.isExcludedFromBackup = !enabled
      try folder.setResourceValues(values)
    }
  }
}
