import Foundation
import IntakeKit
import Security

enum DeviceSession {
  static func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Intake.server-session",
      kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false,
    ]
  }
  static func load(_ key: String) throws -> String? {
    var q = query(key)
    q[kSecReturnData as String] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let bytes = value as? Data,
      let token = String(data: bytes, encoding: .utf8)
    else { throw Problem.message("Unlock this device to access the server session.") }
    return token
  }
  static func set(_ key: String, _ token: String?) throws {
    let q = query(key)
    if let token {
      let fields: [String: Any] = [
        kSecValueData as String: Data(token.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      var status = SecItemUpdate(q as CFDictionary, fields as CFDictionary)
      if status == errSecItemNotFound {
        status = SecItemAdd(q.merging(fields) { _, b in b } as CFDictionary, nil)
      }
      guard status == errSecSuccess else {
        throw Problem.message("Could not save the device session.")
      }
    } else {
      let status = SecItemDelete(q as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw Problem.message("Could not remove the device session.")
      }
    }
  }
}
