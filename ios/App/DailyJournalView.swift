import IntakeKit
import SwiftUI

struct DailyJournalView: View {
  @EnvironmentObject private var model: JournalModel
  @Environment(\.journalPalette) private var palette
  @State private var selected: String
  @State private var anchor: String
  @State private var editing: PageDate?
  @State private var jumping = false
  @State private var lastToday: String
  private struct PageDate: Identifiable { let id: String }

  init(today: String) {
    _lastToday = State(initialValue: today)
    _selected = State(initialValue: today)
    _anchor = State(initialValue: today)
  }
  // Keep page identities stable on swipes; only shift the window at an edge.
  private var window: [String] { (-3...3).map { JournalDay.offset(anchor, by: $0) } }
  private func jump(_ day: String) {
    if !window.contains(day) { anchor = day }
    selected = day
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack {
          Button {
            withAnimation { jump(JournalDay.offset(selected, by: -1)) }
          } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 44)
          }.accessibilityLabel("Previous day")
          Spacer()
          Button {
            jumping = true
          } label: {
            VStack(spacing: 3) {
              Text(
                JournalTime.instant(selected + "T12:00:00Z") ?? .now,
                format: .dateTime.weekday(.wide)
              )
              .font(.caption).foregroundStyle(.secondary)
              HStack(spacing: 5) {
                Text(
                  JournalTime.instant(selected + "T12:00:00Z") ?? .now,
                  format: .dateTime.month(.wide).day().year())
                Image(systemName: "chevron.down").font(.caption)
              }.font(.headline)
            }
          }.environment(\.timeZone, .gmt).accessibilityHint("Choose a journal date")
          Spacer()
          Button {
            withAnimation { jump(JournalDay.offset(selected, by: 1)) }
          } label: {
            Image(systemName: "chevron.right").frame(width: 44, height: 44)
          }.accessibilityLabel("Next day")
        }.padding(.horizontal)
        TabView(selection: $selected) {
          ForEach(window, id: \.self) { day in
            JournalPage(day: day, edit: { editing = PageDate(id: day) }).tag(day)
          }
        }.tabViewStyle(.page(indexDisplayMode: .never))
      }
      .background(JournalPalette.color(palette.background) ?? .clear)
      .navigationTitle("Journal")
      .toolbar {
        Button("Today") { jump(JournalTime.day(.now, settings: model.state.settings)) }
      }
      .onAppear {
        let now = JournalTime.day(.now, settings: model.state.settings)
        if selected == lastToday { jump(now) }
        lastToday = now
      }
      .onChange(of: selected) { _, day in
        if day == window.first || day == window.last { anchor = day }
      }
      .popover(isPresented: $jumping) {
        DatePicker(
          "Journal date",
          selection: .init(
            get: {
              JournalTime.instant(selected + "T12:00:00Z") ?? .now
            },
            set: { date in
              jump(JournalTime.day(date, settings: Settings(timezone: "UTC")))
              jumping = false
            }), displayedComponents: .date
        )
        .datePickerStyle(.graphical).environment(\.timeZone, .gmt)
        .padding().presentationCompactAdaptation(.popover)
      }
      .sheet(item: $editing) { DayEditor(day: $0.id) }
    }
  }
}

private struct JournalPage: View {
  @EnvironmentObject var model: JournalModel
  @Environment(\.journalPalette) private var palette
  let day: String, edit: () -> Void
  var body: some View {
    let notes = model.display.notesByDay[day] ?? []
    let entries = model.display.entriesByDay[day] ?? []
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          if notes.count > 1 {
            Text("Conflicting Daily Journal entries").font(.headline)
            Text("Choose the Daily Journal entry to keep in Settings.").foregroundStyle(.secondary)
          }
          ForEach(notes) { row in
            if !row.text("note").isEmpty { DailyJournalText(row: row).textSelection(.enabled) }
          }
          if notes.count < 2 {
            Button(action: edit) {
              Label(
                notes.first?.text("note").isEmpty != false
                  ? "Write Daily Journal" : "Edit Daily Journal",
                systemImage: "square.and.pencil")
            }.buttonStyle(.bordered)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        Divider()
        VStack(alignment: .leading, spacing: 9) {
          Text("Intake").font(.headline)
          if entries.isEmpty {
            Text(
              notes.contains { $0.data["zero"] == .bool(true) }
                ? "Confirmed zero day" : "No intake logged"
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }
          ForEach(model.display.summaries(entries)) { summary in
            HStack {
              Circle().fill(itemColor(summary.entry)).frame(width: 9, height: 9)
              Text(summary.entry.text("item_name"))
              Spacer()
              Text(summary.amountText).monospacedDigit()
            }.font(.subheadline).accessibilityElement(children: .combine)
          }
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }.background(JournalPalette.color(palette.background) ?? .clear)
  }
}
