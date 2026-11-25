import Charts
import IntakeKit
import SwiftUI

struct HistoryView: View {
  enum Mode: String, CaseIterable {
    case week = "Week"
    case timeline = "Timeline"
    case item = "By item"
    case calendar = "Calendar"
  }
  @EnvironmentObject var m: JournalModel
  @State private var mode = Mode.week
  @State private var anchor = Date()
  @State private var filter = ""
  @State private var amountChart = false
  @State private var from = Date()
  @State private var to = Date()
  @State private var custom = false
  @State private var selected: Record?
  @State private var selectedDay: ChosenDay?
  struct ChosenDay: Identifiable { var id: String }
  var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.firstWeekday = 2
    c.timeZone = TimeZone(identifier: m.state.settings.timezone) ?? .gmt
    return c
  }
  func civil(_ date: Date) -> String {
    JournalTime.day(date, settings: Settings(timezone: m.state.settings.timezone))
  }
  var range: (String, String) {
    if custom { return (civil(from), civil(to)) }
    let unit: Calendar.Component = mode == .calendar ? .month : .weekOfYear
    let i = calendar.dateInterval(of: unit, for: anchor)!
    return (civil(i.start), civil(i.end.addingTimeInterval(-1)))
  }
  var days: [String] {
    let f = DateFormatter()
    f.calendar = calendar
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    let (a, b) = range
    guard var d = f.date(from: a) else { return [] }
    var values: [String] = []
    while civil(d) <= b, values.count < 366 {
      values.append(civil(d))
      guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
      d = next
    }
    return values
  }
  struct Point: Identifiable {
    let day: String, series: String, value: Double
    var id: String { day + series }
  }
  func byDay() -> [String: [Record]] {
    var groups: [String: [Record]] = [:]
    for e in m.state.visible(.entry) {
      if let instant = JournalTime.instant(e.text("occurred_at")) {
        groups[JournalTime.day(instant, settings: m.state.settings), default: []].append(e)
      }
    }
    return groups
  }
  func filtered(_ r: [Record]) -> [Record] {
    r.filter { filter.isEmpty || $0.text("item_id") == filter }
  }
  func points(_ buckets: [String: [Record]]) -> [Point] {
    days.flatMap { day in
      Dictionary(grouping: filtered(buckets[day] ?? [])) { e in
        e.text("item_id") + "|" + e.text("unit")
      }.values.map { entries in
        let e = entries[0]
        let value = entries.reduce(0.0) {
          $0 + (amountChart ? Double($1.text("quantity")) ?? 0 : 1)
        }
        return Point(
          day: day, series: e.text("item_name") + " (" + e.text("unit") + ")", value: value)
      }
    }
  }
  var body: some View {
    NavigationStack {
      List {
        let buckets = byDay()
        Section {
          Picker("View", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
          }.pickerStyle(.segmented)
          Picker("Item", selection: $filter) {
            Text("All items").tag("")
            ForEach(m.state.visible(.item)) { Text($0.text("name")).tag($0.id) }
          }
          Toggle("Custom dates", isOn: $custom)
          if custom {
            DatePicker("From", selection: $from, displayedComponents: .date)
            DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
          } else {
            HStack {
              Button {
                step(-1)
              } label: {
                Image(systemName: "chevron.left")
              }.accessibilityLabel("Previous period")
              Spacer()
              Text("\(range.0) – \(range.1)").font(.caption)
              Spacer()
              Button {
                step(1)
              } label: {
                Image(systemName: "chevron.right")
              }.accessibilityLabel("Next period")
            }.buttonStyle(.borderless)
          }
        }
        if mode == .week {
          Section("Weekly totals") {
            Toggle("Show quantities", isOn: $amountChart)
            Chart(points(buckets)) { p in
              BarMark(
                x: .value("Day", p.day), y: .value(amountChart ? "Quantity" : "Count", p.value)
              )
              .position(by: .value("Item and unit", p.series)).foregroundStyle(
                by: .value("Item and unit", p.series))
            }.frame(height: 160)
          }
        }
        if mode == .calendar {
          Section("Calendar") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
              if let first = days.first, let noon = JournalTime.instant(first + "T12:00:00Z") {
                let weekday = Calendar(identifier: .iso8601).component(.weekday, from: noon)
                ForEach(0..<((weekday + 5) % 7), id: \.self) { _ in Color.clear.frame(height: 1) }
              }
              ForEach(days, id: \.self) { day in
                let all = buckets[day] ?? []
                let zero = m.state.visible(.day).contains {
                  $0.text("date") == day && $0.data["zero"] == .bool(true)
                }
                let count = filtered(all).count
                Button {
                  selectedDay = ChosenDay(id: day)
                } label: {
                  VStack {
                    Text(String(day.suffix(2)))
                    Text(count > 0 ? "\(count)" : (all.isEmpty && zero ? "0" : "·")).font(.caption)
                  }
                }.buttonStyle(.borderless).accessibilityLabel(
                  "\(day), \(count > 0 ? "\(count) entries" : all.isEmpty && zero ? "confirmed zero" : "no matching entries")"
                )
              }
            }
          }
        }
        if mode == .item {
          let grouped = Dictionary(grouping: days.flatMap { filtered(buckets[$0] ?? []) }) {
            $0.text("item_id")
          }
          ForEach(grouped.keys.sorted(), id: \.self) { id in
            let rows = grouped[id] ?? []
            Section(rows.first?.text("item_name") ?? "") {
              Text(totals(rows))
              Text(
                "\(rows.count) entries · \(days.filter { buckets[$0]?.contains { $0.text("item_id") == id } == true }.count) recorded days"
              )
              if let median = medianGap(rows) {
                Text("Median interval: \(Duration.seconds(median).formatted())")
              }
              ForEach(rows) { row in
                Button {
                  selected = row
                } label: {
                  EntryLine(row: row)
                }
              }
            }
          }
        }
        ForEach(days.reversed(), id: \.self) { day in
          let rows = filtered(buckets[day] ?? [])
          let dayNote = m.state.visible(.day).first { $0.text("date") == day }
          if !rows.isEmpty || dayNote != nil {
            Section {
              if let dayNote {
                if !dayNote.text("note").isEmpty { Text(dayNote.text("note")) }
                if dayNote.data["zero"] == .bool(true) && (buckets[day] ?? []).isEmpty {
                  Text("Confirmed zero")
                }
              }
              if mode != .item {
                ForEach(rows) { r in
                  Button {
                    selected = r
                  } label: {
                    EntryLine(row: r)
                  }
                }
              }
            } header: {
              Button(day) { selectedDay = ChosenDay(id: day) }
            }
          }
        }
      }.navigationTitle("History").sheet(item: $selected) { EntryEditor(row: $0) }
        .sheet(item: $selectedDay) { d in
          NavigationStack {
            List {
              ForEach(filtered(byDay()[d.id] ?? [])) { row in
                NavigationLink {
                  EntryEditor(row: row)
                } label: {
                  EntryLine(row: row)
                }
              }
              NavigationLink("Day note and zero day") { DayEditor(day: d.id) }
            }.navigationTitle(d.id)
          }
        }
    }
  }
  func step(_ direction: Int) {
    anchor =
      calendar.date(
        byAdding: mode == .calendar ? .month : .weekOfYear, value: direction, to: anchor) ?? anchor
  }
  func medianGap(_ rows: [Record]) -> Double? {
    let times = rows.compactMap { JournalTime.instant($0.text("occurred_at")) }.sorted()
    guard times.count > 1 else { return nil }
    let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.sorted()
    return (gaps[gaps.count / 2] + gaps[(gaps.count - 1) / 2]) / 2
  }
}
