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
    func text(_ key: String, _ label: String, max: Int, allowEmpty: Bool = false) throws {
      guard case .string(let s) = r.data[key] else {
        throw Problem.message("\(label) must be text.")
      }
      if !allowEmpty && s.isEmpty { throw Problem.message("\(label) is required.") }
      if s.unicodeScalars.count > max {
        throw Problem.message("\(label) must be \(max) characters or fewer.")
      }
    }
    func color() throws {
      guard r.text("color").range(of: #"^#[0-9a-fA-F]{6}\z"#, options: .regularExpression) != nil
      else { throw Problem.message("Color must contain six hex digits after #, such as #7552AA.") }
    }
    func amount(_ value: Value?, label: String) throws {
      guard let value, JournalTime.decimal(value.text) != nil else {
        throw Problem.message(
          "\(label) must be a positive number no greater than 1 trillion, written in 64 characters or fewer."
        )
      }
    }
    guard UUID(uuidString: r.id) != nil else { throw Problem.message("Invalid record ID.") }
    let keys: Set<String>
    switch r.entity {
    case .item:
      keys = ["name", "unit", "amount", "presets", "color", "archived", "order"]
      try text("name", "Item name", max: 200)
      try text("unit", "Unit", max: 64)
      try color()
      try amount(r.data["amount"], label: "Default amount")
      guard case .array(let presets) = r.data["presets"], presets.count <= 30 else {
        throw Problem.message("Presets must be a list of at most 30 amounts.")
      }
      for (index, preset) in presets.enumerated() {
        try amount(preset, label: "Preset \(index + 1)")
      }
      guard case .bool = r.data["archived"] else {
        throw Problem.message("Archived must be true or false.")
      }
      guard case .number(let order) = r.data["order"],
        let exact = Int(NSDecimalNumber(decimal: order).stringValue),
        (-1_000_000...1_000_000).contains(exact)
      else {
        throw Problem.message("Item order must be a whole number from −1,000,000 to 1,000,000.")
      }
    case .entry:
      keys = [
        "item_id", "item_name", "unit", "quantity", "color", "occurred_at", "timezone", "note",
      ]
      try amount(r.data["quantity"], label: "Amount")
      try text("item_name", "Item name", max: 200)
      try text("unit", "Unit", max: 64)
      try color()
      try text("note", "Note", max: 10_000, allowEmpty: true)
      guard UUID(uuidString: r.text("item_id")) != nil else {
        throw Problem.message("Item ID must be a valid UUID.")
      }
      guard TimeZone(identifier: r.text("timezone")) != nil else {
        throw Problem.message(
          "Time zone must be a recognized identifier, such as America/New_York.")
      }
      guard JournalTime.instant(r.text("occurred_at")) != nil else {
        throw Problem.message(
          "Timestamp must include a date, a time, and a UTC offset (Z or ±HH:MM).")
      }
    case .day:
      keys = ["date", "note", "zero"]
      let day = r.text("date")
      try text("note", "Day note", max: 10_000, allowEmpty: true)
      guard case .bool = r.data["zero"] else {
        throw Problem.message("Zero day must be true or false.")
      }
      guard day.count == 10,
        let instant = JournalTime.instant(day + "T12:00:00Z"),
        JournalTime.day(instant, settings: Settings(timezone: "UTC")) == day
      else { throw Problem.message("Day date must be a calendar date in YYYY-MM-DD format.") }
    }
    if let extra = Set(r.data.keys).subtracting(keys).sorted().first {
      throw Problem.message("Unexpected \(r.entity.rawValue) field: \(extra).")
    }
  }
}
