import Foundation

/// Formatting is optional: the note itself stays ordinary, portable text.
public struct DayStyle: Equatable {
  public let range: NSRange
  public let flags: Int
  public init(range: NSRange, flags: Int) {
    self.range = range
    self.flags = flags
  }
  public var wire: Value {
    .array([range.location, range.length, flags].map { .number(Decimal($0)) })
  }

  public static func spans(in record: Record) throws -> [Self] {
    guard let raw = record.data["styles"] else { return [] }
    let invalid = Problem.message("Journal formatting must use valid, nonoverlapping text ranges.")
    guard case .array(let runs) = raw, runs.count <= 10_000 else { throw invalid }
    let units = Array(record.text("note").utf16)
    func boundary(_ i: Int) -> Bool {
      i == units.count || !(0xDC00...0xDFFF).contains(units[i])
    }
    var last = 0
    return try runs.map { run in
      guard case .array(let triple) = run, triple.count == 3 else { throw invalid }
      let ints = triple.compactMap { value -> Int? in
        guard case .number = value else { return nil }
        return Int(value.text)
      }
      guard ints.count == 3 else { throw invalid }
      let (start, length, flags) = (ints[0], ints[1], ints[2])
      guard start >= last, start <= units.count, length > 0, length <= units.count - start,
        (1...3).contains(flags), boundary(start), boundary(start + length)
      else { throw invalid }
      last = start + length
      return Self(range: NSRange(location: start, length: length), flags: flags)
    }
  }
}

/// Date keys describe calendar days in the journal, independent of the device
/// timezone. Use noon UTC for arithmetic so DST can't skip or repeat a page.
public enum JournalDay {
  public static func offset(_ key: String, by days: Int) -> String {
    guard let date = JournalTime.instant(key + "T12:00:00Z") else { return key }
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    guard let next = c.date(byAdding: .day, value: days, to: date) else { return key }
    return JournalTime.day(next, settings: Settings(timezone: "UTC"))
  }
}
