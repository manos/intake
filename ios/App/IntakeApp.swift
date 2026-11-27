import IntakeKit
import SwiftUI

@main struct IntakeApp: App {
  @StateObject private var model = JournalModel()
  @AppStorage("appearance.accent") private var accent: AppAccent = .purple
  private var appearance = AppearancePreferences()
  @Environment(\.scenePhase) private var phase
  private var showingMessage: SwiftUI.Binding<Bool> {
    SwiftUI.Binding(
      get: { model.message != nil },
      set: { visible in if !visible { model.message = nil } })
  }
  private var mainTabs: some View {
    TabView {
      TodayView().tabItem { Label("Today", systemImage: "clock") }
      DailyJournalView(today: JournalTime.day(.now, settings: model.state.settings))
        .tabItem { Label("Journal", systemImage: "book.pages") }
      HistoryView().tabItem { Label("History", systemImage: "calendar") }
      SettingsView(accent: $accent).tabItem { Label("Settings", systemImage: "gearshape") }
    }.id(model.scope)
  }
  var body: some Scene {
    WindowGroup {
      Group {
        if model.ready {
          mainTabs
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
      .environmentObject(model).environment(\.journalPalette, appearance.palette)
      .foregroundColor(JournalPalette.color(appearance.text))
      .tint(JournalPalette.color(appearance.accent) ?? accent.color)
      .alert("Intake", isPresented: showingMessage) {
        Button("OK") { model.message = nil }
      } message: {
        Text(model.message ?? "")
      }
      .onChange(of: phase, initial: true) { _, p in model.lifecycle(p == .active) }
      .task(
        id: phase == .active && model.signedIn && model.state.connectionEnabled
          ? model.state.binding?.key : nil
      ) {
        guard phase == .active, model.signedIn, model.state.connectionEnabled else { return }
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(60)) } catch { return }
          model.refreshIdleConnection()
        }
      }
    }
  }
}

func itemColor(_ r: Record) -> Color {
  let n = UInt32(r.text("color").dropFirst(), radix: 16) ?? 0x7957ab
  return Color(
    red: Double(n >> 16) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
}
func totals(_ summaries: [JournalDisplay.Summary]) -> String {
  summaries.map { "\($0.entry.text("item_name")): \($0.amountText)" }.joined(separator: " · ")
}
private struct ConnectionCloud: View {
  let connected: Bool
  let toggle: () -> Void
  var body: some View {
    Button(action: toggle) {
      Image(systemName: connected ? "icloud.fill" : "icloud.slash")
        .foregroundStyle(connected ? Color.green : Color.secondary)
        .frame(width: 44, height: 44).contentShape(Rectangle())
    }
    .accessibilityLabel(connected ? "Disconnect from server" : "Connect to server")
    .accessibilityHint(
      connected ? "Pause sync and keep logging on this iPhone" : "Resume sync for this journal")
  }
}
struct EntryLine: View {
  let row: Record
  let timezone: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(row.text("item_name")) · \(row.text("quantity")) \(row.text("unit"))")
      if let d = JournalTime.instant(row.text("occurred_at")) {
        Text(d, format: .dateTime.month(.abbreviated).day().year().hour().minute().second())
          .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
          .font(.caption).foregroundStyle(.secondary)
      }
      if !row.text("note").isEmpty { Text(row.text("note")).font(.subheadline) }
    }
  }
}
struct TodayView: View {
  @EnvironmentObject var m: JournalModel
  @Environment(\.scenePhase) private var phase
  @State private var edit: Record?
  @State private var adding = false
  @State private var dayEditor = false
  @State private var details: Record?
  @State private var successID: UUID?
  var body: some View {
    NavigationStack {
      let today = m.display.day(m.todayKey)
      JournalList {
        Section("Items") {
          ForEach(m.display.activeItems) { row in
            HStack {
              Button {
                m.edit(row.entry(settings: m.state.settings))
              } label: {
                HStack {
                  Image(systemName: "plus.circle.fill").foregroundStyle(itemColor(row))
                  VStack(alignment: .leading) {
                    Text(row.text("name"))
                    Text("Log \(row.text("amount")) \(row.text("unit"))").font(.caption)
                    if let d = today.lastTaken[row.id] {
                      Text(d, style: .relative).font(.caption2)
                    }
                  }
                }
              }.buttonStyle(.borderless).layoutPriority(1).accessibilityLabel(
                "Log \(row.text("name")), \(row.text("amount")) \(row.text("unit"))")
              let presets = row.data["presets"]?.values.map(\.text) ?? []
              InlinePresets(amounts: presets, item: row) { amount in
                m.edit(row.entry(settings: m.state.settings, amount: amount))
              }.frame(maxWidth: .infinity, alignment: .trailing)
              Menu {
                Button("Log with details") { edit = row.entry(settings: m.state.settings) }
                ForEach(presets.indices, id: \.self) { index in
                  let amount = presets[index]
                  Button("Log \(amount) \(row.text("unit"))") {
                    m.edit(row.entry(settings: m.state.settings, amount: amount))
                  }
                }
                Button("Edit item") { details = row }
              } label: {
                Image(systemName: "ellipsis.circle")
              }.fixedSize().layoutPriority(1).accessibilityLabel(
                "Options for \(row.text("name"))")
            }
          }
          Button("Add item", systemImage: "plus") { adding = true }
        }
        Section("Today’s journal") {
          let entries = today.entries
          if let dayRow = today.journal {
            DailyJournalText(row: dayRow)
            if dayRow.data["zero"] == .bool(true) && entries.isEmpty {
              Text("Confirmed zero").font(.caption)
            }
          }
          Button {
            dayEditor = true
          } label: {
            JournalActionLabel(title: "Edit Daily Journal")
          }.buttonStyle(.borderless)
          if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              Text("Daily totals").font(.caption.weight(.semibold))
              Text(totals(m.display.summaries(entries))).font(.subheadline)
            }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
          }
          ForEach(entries) { r in
            Button {
              edit = r
            } label: {
              EntryLine(row: r, timezone: m.state.settings.timezone)
            }
          }
        }
        if let undo = m.undo {
          Button("Undo deleted entry") {
            m.edit(undo)
            m.undo = nil
          }
        }
      }
      .task(id: phase) {
        guard phase == .active else { return }
        while !Task.isCancelled {
          m.updateToday()
          let remaining = 60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
          do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        }
      }
      .onAppear { m.updateToday() }
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
      ) { _ in m.updateToday() }
      .refreshable {
        await manualRefresh()
      }
      .overlay(alignment: .topTrailing) {
        if successID != nil && m.connectionBadge == .connected {
          Text("Success!").font(.caption.weight(.medium)).padding(.horizontal, 10).padding(
            .vertical, 5
          )
          .background(.regularMaterial, in: Capsule()).padding(.trailing).allowsHitTesting(false)
        }
      }
      .toolbar {
        if let connected = m.cloudConnected {
          ToolbarItem(placement: .topBarTrailing) {
            ConnectionCloud(connected: connected, toggle: m.toggleConnection).disabled(
              !m.canToggleConnection)
          }
        }
      }
      .task(id: successID) {
        guard successID != nil else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        successID = nil
      }
      .navigationTitle("Today").sheet(item: $edit) { EntryEditor(row: $0) }
      .sheet(isPresented: $adding) { ItemEditor(row: nil) }
      .sheet(item: $details) { ItemEditor(row: $0) }
      .sheet(isPresented: $dayEditor) {
        DayEditor(day: JournalTime.day(.now, settings: m.state.settings))
      }
    }
  }
  @MainActor private func manualRefresh() async {
    successID = nil
    if await m.pullToSync() {
      successID = UUID()
      AccessibilityNotification.Announcement("Sync successful").post()
    }
  }
}

private struct JournalActionLabel: View {
  let title: String
  static let minimumWidth: CGFloat = 44
  var body: some View {
    Text(title).font(.subheadline.weight(.semibold))
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(.tint.opacity(0.12), in: Capsule())
      .frame(minWidth: Self.minimumWidth, minHeight: 44).contentShape(Rectangle())
  }
}

private struct InlinePresets: View {
  let amounts: [String]
  let item: Record
  let log: (String) -> Void
  private let spacing: CGFloat = 6

  var body: some View {
    if !amounts.isEmpty {
      Text("0").font(.subheadline.weight(.semibold)).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 44).hidden().accessibilityHidden(true)
        .overlay {
          GeometryReader { bounds in
            // Each button is at least 44pt wide. Never construct prefixes
            // that cannot possibly fit the space remaining in this row.
            let count = min(
              amounts.count,
              max(
                0, Int((bounds.size.width + spacing) / (JournalActionLabel.minimumWidth + spacing)))
            )
            fitted(count).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
          }
        }
    }
  }
  private func fitted(_ count: Int) -> some View {
    ViewThatFits(in: .horizontal) {
      ForEach((0..<count).reversed(), id: \.self) { last in
        HStack(spacing: spacing) {
          ForEach(0...last, id: \.self) { index in
            let amount = amounts[index]
            let unit = item.text("unit")
            Button {
              log(amount)
            } label: {
              JournalActionLabel(title: "\(amount) \(unit)")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Log \(amount) \(unit) of \(item.text("name"))")
          }
        }.fixedSize()
      }
      Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
    }
  }
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
      JournalForm {
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
      JournalForm {
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
          if m.state.records[row.id] == nil {
            row.data["order"] = .number(
              Decimal(min(1_000_000, (Int(m.display.items.last?.text("order") ?? "") ?? -1) + 1)))
          }
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
