import IntakeKit
import SwiftUI
import UIKit

struct DailyJournalText: View {
  let row: Record
  private var formatted: AttributedString {
    let plain = row.text("note") as NSString
    var result = AttributedString()
    var start = 0
    for run in (try? DayStyle.spans(in: row)) ?? [] {
      result.append(
        AttributedString(
          plain.substring(with: NSRange(location: start, length: run.range.location - start))))
      var part = AttributedString(plain.substring(with: run.range))
      let font: Font = run.flags & 2 != 0 ? .title2 : .body
      part.font = run.flags & 1 != 0 ? font.bold() : font
      result.append(part)
      start = NSMaxRange(run.range)
    }
    result.append(AttributedString(plain.substring(from: start)))
    return result
  }
  var body: some View { Text(formatted).frame(maxWidth: .infinity, alignment: .leading) }
}

@MainActor private final class DayDraft: ObservableObject {
  let original: Record?
  private var contents: NSAttributedString
  weak var field: UITextView?
  @Published private(set) var flags = 0
  init(_ row: Record?) {
    original = row
    contents = JournalTypography.text(for: row)
  }
  func attach(_ view: UITextView) {
    if let old = field { detach(old) }
    field = view
    view.attributedText = contents
    if contents.length == 0 {
      view.typingAttributes = [
        .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label,
      ]
    }
    trackStyle()
  }
  func detach(_ view: UITextView) {
    guard field === view else { return }
    contents = NSAttributedString(attributedString: view.attributedText)
    field = nil
  }
  func trackStyle() {
    guard let field else { return }
    let current = JournalTypography.selectedStyle(in: field)
    if flags != current { flags = current }
  }
  func toggleBold() {
    guard let field else { return }
    field.becomeFirstResponder()
    field.toggleBoldface(nil)
    trackStyle()
  }
  func setHeading(_ enabled: Bool) {
    guard let field else { return }
    field.becomeFirstResponder()
    JournalTypography.setHeading(enabled, in: field)
    trackStyle()
  }
  func record(day: String, zero: Bool) -> Record {
    let value = field?.attributedText ?? contents
    var row = original ?? Record(.day, id: JournalTime.dayID(day), data: [:])
    row.data = ["date": .string(day), "note": .string(value.string), "zero": .bool(zero)]
    let spans = JournalTypography.runs(in: value, traits: field?.traitCollection).map(\.wire)
    if !spans.isEmpty || original?.data["styles"] != nil { row.data["styles"] = .array(spans) }
    return row
  }
}

private struct DayTextInput: UIViewRepresentable {
  let draft: DayDraft
  @Environment(\.journalPalette) private var palette
  final class Coordinator: NSObject, UITextViewDelegate {
    let draft: DayDraft
    var textColorKey: String?
    init(_ draft: DayDraft) { self.draft = draft }
    func textViewDidChangeSelection(_ textView: UITextView) { draft.trackStyle() }
    func textViewDidChange(_ textView: UITextView) { draft.trackStyle() }
    func textViewDidBeginEditing(_ textView: UITextView) { draft.trackStyle() }
  }
  func makeCoordinator() -> Coordinator { Coordinator(draft) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    JournalTypography.configure(view)
    view.backgroundColor = .systemBackground
    view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
    view.accessibilityLabel = "Daily Journal"
    draft.attach(view)
    view.delegate = context.coordinator
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    view.backgroundColor =
      (JournalPalette.color(palette.surface) ?? JournalPalette.color(palette.background)).map(
        UIColor.init) ?? .systemBackground
    guard context.coordinator.textColorKey != palette.text else { return }
    context.coordinator.textColorKey = palette.text
    let color = JournalPalette.color(palette.text).map(UIColor.init) ?? .label
    let typing = view.typingAttributes
    view.textStorage.addAttribute(
      .foregroundColor, value: color, range: NSRange(location: 0, length: view.textStorage.length))
    view.typingAttributes = typing.merging([.foregroundColor: color]) { _, new in new }
  }
  static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
    coordinator.draft.detach(view)
  }
}

struct DayEditor: View {
  @EnvironmentObject var model: JournalModel
  let day: String
  var body: some View {
    NavigationStack { DayEditForm(day: day, original: model.display.notesByDay[day]?.first) }
  }
}

private struct DayEditForm: View {
  @EnvironmentObject var model: JournalModel
  @Environment(\.journalPalette) private var palette
  @Environment(\.dismiss) var dismiss
  let day: String
  @StateObject private var draft: DayDraft
  @State private var zero: Bool
  init(day: String, original: Record?) {
    self.day = day
    _draft = StateObject(wrappedValue: DayDraft(original))
    _zero = State(initialValue: original?.data["zero"] == .bool(true))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(day).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
      DayTextInput(draft: draft).frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      Toggle("Confirmed zero day", isOn: $zero).padding()
    }
    .background(JournalPalette.color(palette.background) ?? .clear)
    .navigationTitle("Daily Journal").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker(
            "Text style",
            selection: SwiftUI.Binding(get: { draft.flags & 2 != 0 }, set: { draft.setHeading($0) })
          ) {
            Text("Body").tag(false)
            Text("Heading").tag(true)
          }.pickerStyle(.inline)
          Toggle(
            isOn: SwiftUI.Binding(get: { draft.flags & 1 != 0 }, set: { _ in draft.toggleBold() })
          ) {
            Label("Bold", systemImage: "bold")
          }
        } label: {
          Label("Format", systemImage: "textformat")
        }
        .accessibilityLabel("Format text")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          if model.change({ journal in
            let current = model.display.notesByDay[day] ?? []
            guard current.count <= 1, current.first?.id == draft.original?.id else {
              throw Problem.message("The Daily Journal changed. Reopen it before saving.")
            }
            try journal.put(draft.record(day: day, zero: zero))
          }) {
            dismiss()
          }
        }
      }
    }
  }
}
