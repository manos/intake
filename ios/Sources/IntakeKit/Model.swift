import CryptoKit
import Foundation

public enum Problem: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}

public enum Value: Equatable, Codable {
  case string(String)
  case number(Decimal)
  case bool(Bool)
  case array([Value])
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Decimal.self) {
      self = .number(n)
    } else {
      self = .array(try c.decode([Value].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let x): try c.encode(x)
    case .number(let x): try c.encode(x)
    case .bool(let x): try c.encode(x)
    case .array(let x): try c.encode(x)
    }
  }
  public var text: String {
    switch self {
    case .string(let s): return s
    case .number(let n): return NSDecimalNumber(decimal: n).stringValue
    default: return ""
    }
  }
  public var values: [Value] {
    if case .array(let a) = self { return a }
    return []
  }
}
public enum Entity: String, Codable { case item, entry, day }
public struct Record: Codable, Equatable, Identifiable {
  public var id: String
  public var entity: Entity
  public var version: Int
  public var deleted: Bool
  public var data: [String: Value]
  public init(_ entity: Entity, id: String = UUID().uuidString.lowercased(), data: [String: Value])
  {
    self.entity = entity
    self.id = id
    self.data = data
    version = 0
    deleted = false
  }
  public func text(_ key: String) -> String { data[key]?.text ?? "" }
  public func entry(settings: Settings, amount: String? = nil, at instant: Date = .now) -> Record {
    Record(
      .entry,
      data: [
        "item_id": .string(id), "item_name": .string(text("name")), "color": .string(text("color")),
        "quantity": .string(amount ?? text("amount")), "unit": .string(text("unit")),
        "occurred_at": .string(JournalTime.stamp(instant)), "timezone": .string(settings.timezone),
        "note": .string(""),
      ])
  }
  public var purged: Bool { deleted && data.isEmpty }
  func equivalent(_ other: Self) -> Bool {
    guard entity == other.entity, deleted == other.deleted, data.keys == other.data.keys else {
      return false
    }
    func numeric(_ a: Value?, _ b: Value?) -> Bool {
      guard let x = a?.text, let y = b?.text else { return false }
      return x == y || (JournalTime.exact(x).map { $0 == JournalTime.exact(y) } ?? false)
    }
    return data.keys.allSatisfy { key in
      if ["amount", "quantity"].contains(key) { return numeric(data[key], other.data[key]) }
      if key == "presets" {
        let a = data[key]?.values ?? []
        let b = other.data[key]?.values ?? []
        return a.count == b.count && zip(a, b).allSatisfy { numeric($0.0, $0.1) }
      }
      return data[key] == other.data[key]
    }
  }
}
public struct Settings: Codable, Equatable {
  public var timezone: String
  public var day_start: Int
  public init(timezone: String = TimeZone.current.identifier, day_start: Int = 0) {
    self.timezone = timezone
    self.day_start = day_start
  }
}
public struct Binding: Codable, Equatable {
  public let origin: String, account: String, username: String
  public init(origin: String, account: String, username: String) {
    self.origin = origin
    self.account = account
    self.username = username
  }
  public var key: String { origin + "|" + account }
}
public enum JournalTime {
  /// Text normalization for equality. Numeric display arithmetic can round at 38 digits.
  static func exact(_ value: String) -> String? {
    let fields = value.lowercased().split(separator: "e", omittingEmptySubsequences: false)
    guard fields.count <= 2, var m = fields.first.map(String.init) else { return nil }
    guard let power = fields.count == 1 ? 0 : Int(fields[1]), (-100000...100000).contains(power)
    else { return nil }
    if m.first == "+" { m.removeFirst() }
    let parts = m.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return nil }
    let fraction = parts.count == 2 ? parts[1].count : 0
    var digits = String(parts.joined().drop(while: { $0 == "0" }))
    guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
    var shift = power - fraction
    while digits.last == "0" {
      digits.removeLast()
      shift += 1
    }
    return "\(digits)e\(shift)"
  }
  public static func decimal(_ s: String) -> Decimal? {
    guard s.count <= 64,
      s.range(
        of: #"^[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
        options: .regularExpression) != nil,
      let n = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), n > 0,
      n <= 1_000_000_000_000
    else { return nil }
    return n
  }
  public static func instant(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
      ?? (try? Date.ISO8601FormatStyle().parse(value))
  }
  public static func stamp(_ d: Date) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt).format(d)
  }
  public static func day(_ d: Date, settings: Settings) -> String {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: settings.timezone) ?? .gmt
    let local =
      c.component(.hour, from: d) < settings.day_start
      ? c.date(byAdding: .day, value: -1, to: d) ?? d : d
    let p = c.dateComponents([.year, .month, .day], from: local)
    return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
  }
  public static func dayID(_ day: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(("intake-day:" + day).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 15) | 80
    bytes[8] = (bytes[8] & 63) | 128
    let hex = bytes.map { String(format: "%02x", $0) }
    return [0..<4, 4..<6, 6..<8, 8..<10, 10..<16].map { hex[$0].joined() }.joined(separator: "-")
  }
}
public struct Operation: Codable, Equatable, Identifiable {
  public var id: String, entity: Entity, record_id: String, base_version: Int,
    data: [String: Value], deleted: Bool
  init(_ r: Record, base: Int) {
    id = UUID().uuidString.lowercased()
    entity = r.entity
    record_id = r.id
    base_version = base
    data = r.data
    deleted = r.deleted
  }
}
public struct Conflict: Codable, Equatable {
  public var remote: Record?
  public var reason: String
}
public struct JournalState: Codable {
  public var records: [String: Record] = [:], baseline: [String: Record] = [:]
  public var pending: [Operation] = [], frozen: [String: Data] = [:]
  public var conflicts: [String: Conflict] = [:], purges: [String] = []
  public var importConflicts: [String: Record] = [:]
  public var deletionChoice: Bool?
  public var retryAfter: Date?
  public func maySync(at now: Date) -> Bool { retryAfter.map { $0 <= now } ?? true }
  public var cursor = 0, incomplete = false, customized = false
  public var binding: Binding?, settings = Settings(), settingsConflict: Settings?
  public init() {}
  public var hasLocalData: Bool {
    customized || !records.isEmpty || !pending.isEmpty || !purges.isEmpty
  }
  public var competingDays: [String: [Record]] {
    Dictionary(grouping: visible(.day)) { $0.text("date") }.filter { $0.value.count > 1 }
  }
  public func visible(_ entity: Entity) -> [Record] {
    records.values.filter { $0.entity == entity && !$0.deleted }.sorted {
      if entity == .item, $0.text("order") != $1.text("order") {
        return (Int($0.text("order")) ?? 0) < (Int($1.text("order")) ?? 0)
      }
      if entity == .entry {
        let a = JournalTime.instant($0.text("occurred_at"))
        let b = JournalTime.instant($1.text("occurred_at"))
        if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
      }
      return $0.id < $1.id
    }
  }
}
public struct SyncResult: Codable {
  public let id: String, status: String
  public let record: Record?, message: String?
}
public struct Page: Codable {
  public let results: [SyncResult], changes: [Record], cursor: Int, has_more: Bool
}
