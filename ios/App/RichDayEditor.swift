import IntakeKit
import SwiftUI
import UIKit

private let styleKey = NSAttributedString.Key("IntakeDayStyle")
private func attributes(_ flags: Int) -> [NSAttributedString.Key: Any] {
  let base = UIFont.preferredFont(forTextStyle: flags & 2 != 0 ? .title2 : .body)
  let font =
    flags & 1 != 0
    ? base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) }
      ?? base
    : base
  return [.font: font, .foregroundColor: UIColor.label, styleKey: flags]
}

struct DayNoteText: View {
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
    let text = NSMutableAttributedString(string: row?.text("note") ?? "", attributes: attributes(0))
    if let row {
      for span in (try? DayStyle.spans(in: row)) ?? [] {
        text.addAttributes(attributes(span.flags), range: span.range)
      }
    }
    contents = text
  }
  func attach(_ view: UITextView) {
    if let old = field { detach(old) }
    field = view
    view.attributedText = contents
    view.typingAttributes = attributes(flags)
  }
  func detach(_ view: UITextView) {
    guard field === view else { return }
    contents = NSAttributedString(attributedString: view.attributedText)
    field = nil
  }
  func trackStyle() {
    guard let field else { return }
    let range = field.selectedRange
    let value =
      range.length > 0 && range.location < field.textStorage.length
      ? field.textStorage.attribute(styleKey, at: range.location, effectiveRange: nil) as? Int
      : field.typingAttributes[styleKey] as? Int
    if flags != value ?? 0 { flags = value ?? 0 }
  }
  func set(_ bit: Int, enabled: Bool) {
    guard let field else { return }
    let range = field.selectedRange
    func apply(_ old: Int) -> Int { enabled ? old | bit : old & ~bit }
    if range.length > 0 {
      let storage = field.textStorage
      var changes: [(NSRange, Int)] = []
      storage.enumerateAttribute(styleKey, in: range) { old, r, _ in
        changes.append((r, apply(old as? Int ?? 0)))
      }
      storage.beginEditing()
      for (r, next) in changes { storage.addAttributes(attributes(next), range: r) }
      storage.endEditing()
      field.selectedRange = range
    }
    field.typingAttributes = attributes(apply(flags))
    trackStyle()
  }
  func record(day: String, zero: Bool) -> Record {
    let value = field?.attributedText ?? contents
    var row = original ?? Record(.day, id: JournalTime.dayID(day), data: [:])
    row.data = ["date": .string(day), "note": .string(value.string), "zero": .bool(zero)]
    var spans: [Value] = []
    value.enumerateAttribute(styleKey, in: NSRange(location: 0, length: value.length)) {
      value, range, _ in
      if let flags = value as? Int, (1...3).contains(flags) {
        spans.append(DayStyle(range: range, flags: flags).wire)
      }
    }
    if !spans.isEmpty || original?.data["styles"] != nil { row.data["styles"] = .array(spans) }
    return row
  }
}

private struct DayTextInput: UIViewRepresentable {
  let draft: DayDraft
  final class Coordinator: NSObject, UITextViewDelegate {
    let draft: DayDraft
    init(_ draft: DayDraft) { self.draft = draft }
    func textViewDidChangeSelection(_ textView: UITextView) { draft.trackStyle() }
  }
  func makeCoordinator() -> Coordinator { Coordinator(draft) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.backgroundColor = .secondarySystemGroupedBackground
    view.layer.cornerRadius = 12
    view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
    view.adjustsFontForContentSizeCategory = true
    view.accessibilityLabel = "Day note"
    draft.attach(view)
    view.delegate = context.coordinator
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {}
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
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button {
          draft.set(1, enabled: draft.flags & 1 == 0)
        } label: {
          Image(systemName: "bold").frame(minWidth: 32, minHeight: 32)
        }.buttonStyle(.bordered).accessibilityLabel("Bold")
          .accessibilityValue(draft.flags & 1 == 0 ? "Off" : "On")
          .accessibilityAddTraits(draft.flags & 1 == 0 ? [] : .isSelected)
          .tint(draft.flags & 1 == 0 ? .secondary : .accentColor)
        Picker(
          "Text size",
          selection: SwiftUI.Binding(
            get: { draft.flags & 2 != 0 }, set: { draft.set(2, enabled: $0) })
        ) {
          Text("Body").tag(false)
          Text("Heading").tag(true)
        }.pickerStyle(.segmented)
      }
      DayTextInput(draft: draft).frame(maxWidth: .infinity, maxHeight: .infinity)
      Toggle("Confirmed zero day", isOn: $zero)
    }
    .padding().navigationTitle(day).navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          if model.change({ journal in
            let current = model.display.notesByDay[day] ?? []
            guard current.count <= 1, current.first?.id == draft.original?.id else {
              throw Problem.message("The day note changed. Reopen it before saving.")
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
