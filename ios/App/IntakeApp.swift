import IntakeKit
import SwiftUI

@main struct IntakeApp: App {
  @StateObject private var model = JournalModel()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      Group {
        if model.ready {
          VStack(spacing: 0) {
            TotalsBanner()
            TabView {
              TodayView().tabItem { Label("Today", systemImage: "clock") }
              HistoryView().tabItem { Label("History", systemImage: "calendar") }
              SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
            }.id(model.scope)
          }
        } else {
          ContentUnavailableView {
            Label("Journal unavailable", systemImage: "lock")
          } description: {
            Text(model.message ?? "Unlock the device and reopen your journal.")
          } actions: {
            Button("Retry") { model.open() }
          }
        }
      }
      .environmentObject(model).tint(.purple)
      .alert(
        "Intake",
        isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
      ) {
        Button("OK") { model.message = nil }
      } message: {
        Text(model.message ?? "")
      }
      .onChange(of: phase, initial: true) { _, p in model.lifecycle(p == .active) }
    }
  }
}

func itemColor(_ r: Record) -> Color {
  let n = UInt32(r.text("color").dropFirst(), radix: 16) ?? 0x7957ab
  return Color(
    red: Double(n >> 16) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
}
func totals(_ entries: [Record]) -> String {
  let grouped = Dictionary(grouping: entries) { [$0.text("item_id"), $0.text("unit")] }
  return grouped.values.map { group in
    let n = group.reduce(Decimal.zero) { $0 + (JournalTime.decimal($1.text("quantity")) ?? 0) }
    return
      "\(group[0].text("item_name")): \(NSDecimalNumber(decimal:n).stringValue) \(group[0].text("unit"))"
  }.sorted().joined(separator: " · ")
}
struct TotalsBanner: View {
  @EnvironmentObject var m: JournalModel
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { tick in
      let day = JournalTime.day(tick.date, settings: m.state.settings)
      let rows = m.state.visible(.entry).filter {
        JournalTime.instant($0.text("occurred_at")).map {
          JournalTime.day($0, settings: m.state.settings) == day
        } == true
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(rows.isEmpty ? "Today: no entries" : "Today · \(totals(rows))").font(
          .subheadline.bold())
        if m.state.binding != nil
          && (m.busy || m.state.incomplete || !m.signedIn
            || !["", "Synced"].contains(m.syncStatus))
        {
          Text(
            "\(m.syncStatus.isEmpty ? "Pending" : m.syncStatus) · \(m.state.pending.count + m.state.purges.count) pending"
          ).font(.caption)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
        .background(.thinMaterial)
    }
  }
}
struct EntryLine: View {
  let row: Record
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(row.text("item_name")) · \(row.text("quantity")) \(row.text("unit"))")
      if let d = JournalTime.instant(row.text("occurred_at")) {
        Text(d.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(
          .secondary)
      }
      if !row.text("note").isEmpty { Text(row.text("note")).font(.subheadline) }
    }
  }
}
struct TodayView: View {
  @EnvironmentObject var m: JournalModel
  @State private var edit: Record?
  @State private var adding = false
  @State private var dayEditor = false
  @State private var details: Record?
  var body: some View {
    NavigationStack {
      List {
        Section("Items") {
          ForEach(m.state.visible(.item).filter { $0.data["archived"] != .bool(true) }) { row in
            HStack {
              Button {
                m.edit(makeEntry(row, m.state.settings))
              } label: {
                HStack {
                  Image(systemName: "plus.circle.fill").foregroundStyle(itemColor(row))
                  VStack(alignment: .leading) {
                    Text(row.text("name"))
                    Text("\(row.text("amount")) \(row.text("unit"))").font(.caption)
                    if let last = m.state.visible(.entry).first(where: {
                      $0.text("item_id") == row.id
                    }),
                      let d = JournalTime.instant(last.text("occurred_at"))
                    {
                      Text(d, style: .relative).font(.caption2)
                    }
                  }
                }
              }.buttonStyle(.borderless).accessibilityLabel(
                "Log \(row.text("name")), \(row.text("amount")) \(row.text("unit"))")
              Spacer()
              Menu {
                Button("Log with details") { edit = makeEntry(row, m.state.settings) }
                ForEach(row.data["presets"]?.values.map(\.text) ?? [], id: \.self) { amount in
                  Button("Log \(amount) \(row.text("unit"))") {
                    var e = makeEntry(row, m.state.settings)
                    e.data["quantity"] = .string(amount)
                    m.edit(e)
                  }
                }
                Button("Edit item") { details = row }
              } label: {
                Image(systemName: "ellipsis.circle")
              }.accessibilityLabel("Options for \(row.text("name"))")
            }
          }
          Button("Add item", systemImage: "plus") { adding = true }
        }
        Section("Today’s journal") {
          let day = JournalTime.day(.now, settings: m.state.settings)
          let dayRow = m.state.visible(.day).first { $0.text("date") == day }
          if let dayRow {
            Text(dayRow.text("note"))
            if dayRow.data["zero"] == .bool(true)
              && !m.state.visible(.entry).contains(where: { entry in
                JournalTime.instant(entry.text("occurred_at")).map {
                  JournalTime.day($0, settings: m.state.settings) == day
                } == true
              })
            {
              Text("Confirmed zero").font(.caption)
            }
          }
          Button("Edit day note or zero day") { dayEditor = true }
          ForEach(
            m.state.visible(.entry).filter {
              JournalTime.instant($0.text("occurred_at")).map {
                JournalTime.day($0, settings: m.state.settings) == day
              } == true
            }
          ) { r in
            Button {
              edit = r
            } label: {
              EntryLine(row: r)
            }
          }
        }
        if let undo = m.undo {
          Button("Undo deleted entry") {
            m.edit(undo)
            m.undo = nil
          }
        }
      }.navigationTitle("Today").sheet(item: $edit) { EntryEditor(row: $0) }
        .sheet(isPresented: $adding) { ItemEditor(row: nil) }
        .sheet(item: $details) { ItemEditor(row: $0) }
        .sheet(isPresented: $dayEditor) {
          DayEditor(day: JournalTime.day(.now, settings: m.state.settings))
        }
    }
  }
}
func makeEntry(_ item: Record, _ settings: Settings) -> Record {
  Record(
    .entry,
    data: [
      "item_id": .string(item.id), "item_name": .string(item.text("name")),
      "color": .string(item.text("color")),
      "quantity": .string(item.text("amount")), "unit": .string(item.text("unit")),
      "occurred_at": .string(JournalTime.stamp(.now)), "timezone": .string(settings.timezone),
      "note": .string(""),
    ])
}
struct EntryEditor: View {
  @EnvironmentObject var m: JournalModel
  @Environment(\.dismiss) var dismiss
  @State var row: Record
  @State private var changedTime = false
  @State private var chosenTime = Date()
  var zone: TimeZone { TimeZone(identifier: row.text("timezone")) ?? .current }
  var choices: [Date] {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let start = cal.startOfDay(for: chosenTime).addingTimeInterval(-1)
    let parts = cal.dateComponents([.hour, .minute, .second], from: chosenTime)
    let repeats: [Calendar.RepeatedTimePolicy] = [.first, .last]
    return Array(
      Set(
        repeats.compactMap {
          cal.nextDate(
            after: start, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: $0,
            direction: .forward)
        })
    ).sorted()
  }
  var body: some View {
    NavigationStack {
      Form {
        Text(row.text("item_name"))
        TextField("Quantity (\(row.text("unit")))", text: field("quantity")).keyboardType(
          .decimalPad)
        TextField("Note", text: field("note"), axis: .vertical)
        Toggle("Change exact time", isOn: $changedTime)
        if changedTime {
          DatePicker("Date and time", selection: $chosenTime).environment(\.timeZone, zone)
          Text(zone.identifier).font(.caption)
          if choices.count > 1 {
            Picker("Repeated hour", selection: $chosenTime) {
              ForEach(choices, id: \.self) { d in
                let offset = zone.secondsFromGMT(for: d)
                Text(
                  String(
                    format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 3600,
                    abs(offset) % 3600 / 60)
                ).tag(d)
              }
            }
          }
        } else {
          Text(row.text("occurred_at")).font(.caption)
        }
        if m.state.records[row.id] != nil {
          Button("Delete entry", role: .destructive) {
            m.remove(row)
            dismiss()
          }
        }
      }.navigationTitle("Entry")
        .onAppear { chosenTime = JournalTime.instant(row.text("occurred_at")) ?? .now }
        .toolbar {
          Button("Save") {
            if changedTime, chosenTime != JournalTime.instant(row.text("occurred_at")) {
              row.data["occurred_at"] = .string(JournalTime.stamp(chosenTime))
            }
            if m.change({ try $0.put(row) }) { dismiss() }
          }
          Button("Cancel") { dismiss() }
        }
    }
  }
  func field(_ k: String) -> SwiftUI.Binding<String> {
    .init(get: { row.text(k) }, set: { row.data[k] = .string($0) })
  }
}
struct ItemEditor: View {
  @EnvironmentObject var m: JournalModel
  @Environment(\.dismiss) var dismiss
  @State var row: Record
  @State var presets: String
  @State private var confirm = false
  init(row: Record?) {
    _row = State(
      initialValue: row
        ?? Record(
          .item,
          data: [
            "name": .string(""), "unit": .string(""), "color": .string("#7552aa"),
            "amount": .string("1"), "order": .number(0), "archived": .bool(false),
            "presets": .array([]),
          ]))
    _presets = State(
      initialValue: row?.data["presets"]?.values.map(\.text).joined(separator: ", ") ?? "")
  }
  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: field("name"))
        TextField("Unit", text: field("unit"))
        TextField("Default amount", text: field("amount")).keyboardType(.decimalPad)
        TextField("Amount presets, comma separated", text: $presets)
        HStack {
          Circle().fill(itemColor(row)).frame(width: 20, height: 20)
          TextField("Color (#RRGGBB)", text: field("color")).textInputAutocapitalization(.never)
          ColorPicker(
            "Choose color",
            selection: .init(
              get: { itemColor(row) },
              set: { color in
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
                  row.data["color"] = .string(
                    String(
                      format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()),
                      Int((b * 255).rounded())))
                }
              }), supportsOpacity: false
          ).labelsHidden()
        }
        Toggle(
          "Archived",
          isOn: .init(
            get: { row.data["archived"] == .bool(true) }, set: { row.data["archived"] = .bool($0) })
        )
        if m.state.records[row.id] != nil {
          Button("Permanently delete item", role: .destructive) { confirm = true }
        }
      }.navigationTitle("Item").toolbar {
        Button("Save") {
          row.data["presets"] = .array(
            presets.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
          if m.change({ try $0.put(row) }) { dismiss() }
        }
        Button("Cancel") { dismiss() }
      }
      .confirmationDialog(
        "Permanently delete this item and all its entries?", isPresented: $confirm,
        titleVisibility: .visible
      ) {
        Button("Delete item and entries", role: .destructive) {
          m.purge(row.id)
          dismiss()
        }
      }
    }
  }
  func field(_ k: String) -> SwiftUI.Binding<String> {
    .init(get: { row.text(k) }, set: { row.data[k] = .string($0) })
  }
}
struct DayEditor: View {
  @EnvironmentObject var m: JournalModel
  @Environment(\.dismiss) var dismiss
  let day: String
  @State private var note = ""
  @State private var zero = false
  @State private var original: Record?
  var existing: Record? { m.state.visible(.day).first { $0.text("date") == day } }
  var body: some View {
    NavigationStack {
      Form {
        TextField("Day note", text: $note, axis: .vertical)
        Toggle("Confirmed zero day", isOn: $zero)
      }.navigationTitle(day).onAppear {
        original = existing
        note = existing?.text("note") ?? ""
        zero = existing?.data["zero"] == .bool(true)
      }
      .toolbar {
        Button("Save") {
          var r = Record(
            .day, id: original?.id ?? JournalTime.dayID(day),
            data: ["date": .string(day), "note": .string(note), "zero": .bool(zero)])
          r.version = original?.version ?? 0
          if m.change({ try $0.put(r) }) { dismiss() }
        }
        Button("Cancel") { dismiss() }
      }
    }
  }
}
