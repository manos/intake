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
  @State private var chartDay: String?
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
    let day: String, series: String, value: Double, itemID: String, unit: String, color: Color
    var seriesKey: String { itemID + "|" + unit }
    var id: String { day + seriesKey }
  }
  func filtered(_ r: [Record]) -> [Record] {
    r.filter { filter.isEmpty || $0.text("item_id") == filter }
  }
  func points(_ buckets: [String: [Record]], days: [String]) -> [Point] {
    let result = days.flatMap { day in
      m.display.summaries(filtered(buckets[day] ?? [])).map { summary in
        let e = summary.entry
        let value =
          amountChart
          ? NSDecimalNumber(decimal: summary.quantity).doubleValue : Double(summary.count)
        return Point(
          day: day, series: e.text("item_name") + " (" + e.text("unit") + ")", value: value,
          itemID: e.text("item_id"), unit: summary.unit, color: itemColor(e))
      }
    }
    return result.sorted { a, b in
      if a.itemID != b.itemID { return m.display.precedes(a.itemID, b.itemID) }
      return (a.unit, a.day) < (b.unit, b.day)
    }
  }
  var body: some View {
    NavigationStack {
      JournalList {
        let buckets = m.display.entriesByDay
        let days = self.days
        Section {
          Picker("View", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
          }.pickerStyle(.segmented)
          Picker("Item", selection: $filter) {
            Text("All items").tag("")
            ForEach(m.display.items) { Text($0.text("name")).tag($0.id) }
          }
          Toggle("Custom dates", isOn: $custom)
          if custom {
            DatePicker("From", selection: $from, displayedComponents: .date)
              .onChange(of: from) { _, d in if to < d { to = d } }
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
            let values = points(buckets, days: days)
            Chart(values) { p in
              BarMark(
                x: .value("Day", p.day), y: .value(amountChart ? "Quantity" : "Count", p.value)
              )
              .position(by: .value("Item and unit", p.seriesKey)).foregroundStyle(p.color)
              .accessibilityLabel("\(p.day), \(p.series)")
            }.chartXScale(domain: days).frame(height: 160)
              .chartXSelection(value: $chartDay)
              .onChange(of: chartDay) { _, d in
                if let d {
                  selectedDay = ChosenDay(id: d)
                  chartDay = nil
                }
              }
            ScrollView(.horizontal, showsIndicators: false) {
              HStack {
                ForEach(legend(values), id: \.seriesKey) { p in
                  HStack(spacing: 4) {
                    Circle().fill(p.color).frame(width: 8, height: 8)
                    Text(p.series).font(.caption)
                  }
                }
              }
            }
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
                let zero =
                  m.display.notesByDay[day]?.contains { $0.data["zero"] == .bool(true) } ?? false
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
          ForEach(grouped.keys.sorted(by: m.display.precedes), id: \.self) { id in
            let rows = grouped[id] ?? []
            Section(rows.first?.text("item_name") ?? "") {
              Text(totals(m.display.summaries(rows)))
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
                  EntryLine(row: row, timezone: m.state.settings.timezone)
                }
              }
            }
          }
        }
        ForEach(days.reversed(), id: \.self) { day in
          let rows = filtered(buckets[day] ?? [])
          let dailyJournal = m.display.notesByDay[day]?.first
          if !rows.isEmpty || dailyJournal != nil {
            Section {
              if let dailyJournal {
                if !dailyJournal.text("note").isEmpty { DailyJournalText(row: dailyJournal) }
                if dailyJournal.data["zero"] == .bool(true) && (buckets[day] ?? []).isEmpty {
                  Text("Confirmed zero")
                }
              }
              if mode != .item {
                if mode == .timeline && !rows.isEmpty {
                  ClockTimeline(entries: rows, settings: m.state.settings) { selected = $0 }
                }
                ForEach(rows) { r in
                  Button {
                    selected = r
                  } label: {
                    EntryLine(row: r, timezone: m.state.settings.timezone)
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
            JournalList {
              ForEach(filtered(m.display.entriesByDay[d.id] ?? [])) { row in
                NavigationLink {
                  EntryEditor(row: row)
                } label: {
                  EntryLine(row: row, timezone: m.state.settings.timezone)
                }
              }
              NavigationLink("Daily Journal") { DayEditor(day: d.id) }
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
  private func legend(_ points: [Point]) -> [Point] {
    var seen = Set<String>()
    return points.filter { seen.insert($0.seriesKey).inserted }
  }
  func medianGap(_ rows: [Record]) -> Double? {
    let times = rows.compactMap { JournalTime.instant($0.text("occurred_at")) }.sorted()
    guard times.count > 1 else { return nil }
    let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.sorted()
    return (gaps[gaps.count / 2] + gaps[(gaps.count - 1) / 2]) / 2
  }
}

/// One lane per event keeps repeated fall-back times and simultaneous logs selectable.
private struct ClockTimeline: View {
  let entries: [Record], settings: Settings, select: (Record) -> Void
  var body: some View {
    VStack(alignment: .leading) {
      Text("24 hours from \(settings.day_start):00").font(.caption)
      ForEach(entries.reversed()) { row in
        if let instant = JournalTime.instant(row.text("occurred_at")) {
          let zone = TimeZone(identifier: settings.timezone) ?? .gmt
          let parts = Calendar(identifier: .gregorian).dateComponents(in: zone, from: instant)
          let minute = ((parts.hour ?? 0) - settings.day_start + 24) % 24 * 60 + (parts.minute ?? 0)
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Capsule().fill(.quaternary).frame(height: 2)
              Circle().fill(itemColor(row)).frame(width: 12, height: 12)
                .offset(x: (geometry.size.width - 12) * Double(minute) / 1440)
            }.frame(maxHeight: .infinity).contentShape(Rectangle()).onTapGesture { select(row) }
          }.frame(height: 24).accessibilityElement().accessibilityLabel(
            "\(row.text("item_name")), \(row.text("occurred_at"))"
          )
          .accessibilityAddTraits(.isButton).accessibilityAction { select(row) }
        }
      }
    }
  }
}
