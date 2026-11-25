import Foundation

public enum Transfer {
  static let groups: [(String, Entity)] = [("items", .item), ("entries", .entry), ("days", .day)]
  public static func export(_ state: JournalState) throws -> Data {
    var map: [String: [[String: Value]]] = [:]
    for (key, entity) in groups {
      map[key] = state.visible(entity).map {
        var data = $0.data
        data["id"] = .string($0.id)
        return data
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(map)
  }
  public static func decode(_ data: Data, csv: Bool) throws -> [Record] {
    guard data.count <= 5_000_000 else { throw Problem.message("Choose a file smaller than 5 MB.") }
    let map: [String: [[String: Value]]]
    if csv {
      guard let text = String(data: data, encoding: .utf8) else {
        throw Problem.message("CSV must use UTF-8.")
      }
      var lines = try csvRows(text)
      guard !lines.isEmpty else { throw Problem.message("CSV is empty.") }
      let header = lines.removeFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      guard Set(header).count == header.count else {
        throw Problem.message("Duplicate CSV column.")
      }
      map = [
        "items": [], "days": [],
        "entries": try lines.enumerated().map { i, fields in
          guard fields.count == header.count else {
            throw Problem.message("Column count differs at row \(i+2).")
          }
          var d = Dictionary(uniqueKeysWithValues: zip(header, fields.map(Value.string)))
          if d["id"]?.text == "" { d.removeValue(forKey: "id") }
          if d["note"] == nil { d["note"] = .string("") }
          return d
        },
      ]
    } else {
      map = try JSONDecoder().decode([String: [[String: Value]]].self, from: data)
    }
    var rows: [Record] = []
    var ids = Set<String>()
    var dates = Set<String>()
    for (key, entity) in groups {
      guard let list = map[key] else { throw Problem.message("Missing \(key) list.") }
      for (i, var d) in list.enumerated() {
        let id =
          d.removeValue(forKey: "id")?.text
          ?? (entity == .day
            ? JournalTime.dayID(d["date"]?.text ?? "") : UUID().uuidString.lowercased())
        let r = Record(entity, id: id, data: d)
        do { try validate(r) } catch {
          throw Problem.message("\(key) row \(i+1): \(error.localizedDescription)")
        }
        guard ids.insert(id).inserted else {
          throw Problem.message("Duplicate record ID in import.")
        }
        if entity == .day, !dates.insert(r.text("date")).inserted {
          throw Problem.message("Duplicate day in import.")
        }
        rows.append(r)
      }
    }
    return rows
  }
  static func csvRows(_ text: String) throws -> [[String]] {
    // Parse scalars so CRLF does not become one unrecognized Character.
    let chars = Array(text.unicodeScalars)
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quote = false
    var i = 0
    while i < chars.count {
      let c = chars[i]
      i += 1
      if c == "\"" {
        if quote && i < chars.count && chars[i] == "\"" {
          field += "\""
          i += 1
        } else {
          quote.toggle()
        }
      } else if c == "," && !quote {
        row.append(field)
        field = ""
      } else if !quote && (c == "\n" || c == "\r") {
        if c == "\r" && i < chars.count && chars[i] == "\n" { i += 1 }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        row = []
        field = ""
      } else {
        field.unicodeScalars.append(c)
      }
    }
    guard !quote else { throw Problem.message("Unclosed quote in CSV.") }
    row.append(field)
    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
    return rows
  }
  static func validate(_ r: Record) throws {
    func string(_ key: String, _ max: Int, empty: Bool = false) -> Bool {
      guard case .string(let s) = r.data[key] else { return false }
      return (empty || !s.isEmpty) && s.count <= max
    }
    let color = r.text("color").range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    guard UUID(uuidString: r.id) != nil else { throw Problem.message("Invalid record ID.") }
    let keys: Set<String>
    switch r.entity {
    case .item:
      keys = ["name", "unit", "amount", "presets", "color", "archived", "order"]
      guard string("name", 200), string("unit", 64), color,
        case .bool = r.data["archived"], case .number(let order) = r.data["order"],
        let exact = Int(NSDecimalNumber(decimal: order).stringValue),
        (-1_000_000...1_000_000).contains(exact),
        JournalTime.decimal(r.text("amount")) != nil, case .array(let p) = r.data["presets"],
        p.count <= 30, p.allSatisfy({ JournalTime.decimal($0.text) != nil })
      else { throw Problem.message("Check the item name, unit, quantity, color and presets.") }
    case .entry:
      keys = [
        "item_id", "item_name", "unit", "quantity", "color", "occurred_at", "timezone", "note",
      ]
      guard string("item_name", 200), string("unit", 64), color, string("note", 10000, empty: true),
        UUID(uuidString: r.text("item_id")) != nil, JournalTime.decimal(r.text("quantity")) != nil,
        TimeZone(identifier: r.text("timezone")) != nil,
        JournalTime.instant(r.text("occurred_at")) != nil
      else { throw Problem.message("Check the entry amount, offset timestamp, timezone and item.") }
    case .day:
      keys = ["date", "note", "zero"]
      let day = r.text("date")
      guard string("note", 10000, empty: true), case .bool = r.data["zero"], day.count == 10,
        let instant = JournalTime.instant(day + "T12:00:00Z"),
        JournalTime.day(instant, settings: Settings(timezone: "UTC")) == day
      else { throw Problem.message("Invalid journal day.") }
    }
    guard Set(r.data.keys) == keys else { throw Problem.message("Unexpected or missing fields.") }
  }
}
