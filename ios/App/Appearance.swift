import SwiftUI
import UIKit

/// Empty values inherit the system appearance (including light/dark mode).
struct JournalPalette: Equatable {
  var background = "", surface = "", text = "", accent = ""
  static func color(_ hex: String) -> Color? {
    guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
    return Color(
      .sRGB, red: Double(n >> 16) / 255, green: Double((n >> 8) & 255) / 255,
      blue: Double(n & 255) / 255)
  }
  static func hex(_ color: Color) -> String? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let values = UIColor(color).cgColor.converted(
        to: space, intent: .relativeColorimetric, options: nil)?.components,
      values.count >= 3
    else { return nil }
    return values.prefix(3).map {
      String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded()))
    }.joined()
  }
}
private struct PaletteKey: EnvironmentKey { static let defaultValue = JournalPalette() }
extension EnvironmentValues {
  var journalPalette: JournalPalette {
    get { self[PaletteKey.self] }
    set { self[PaletteKey.self] = newValue }
  }
}
struct AppearancePreferences: DynamicProperty {
  @AppStorage("appearance.background") var background = ""
  @AppStorage("appearance.surface") var surface = ""
  @AppStorage("appearance.text") var text = ""
  @AppStorage("appearance.customAccent") var accent = ""
  var palette: JournalPalette {
    JournalPalette(background: background, surface: surface, text: text, accent: accent)
  }
}

struct JournalList<Content: View>: View {
  @Environment(\.journalPalette) private var palette
  @ViewBuilder var content: Content
  var body: some View {
    List { content.listRowBackground(JournalPalette.color(palette.surface)) }
      .scrollContentBackground(palette.background.isEmpty ? .automatic : .hidden)
      .background(JournalPalette.color(palette.background) ?? .clear)
  }
}
struct JournalForm<Content: View>: View {
  @Environment(\.journalPalette) private var palette
  @ViewBuilder var content: Content
  var body: some View {
    Form { content.listRowBackground(JournalPalette.color(palette.surface)) }
      .scrollContentBackground(palette.background.isEmpty ? .automatic : .hidden)
      .background(JournalPalette.color(palette.background) ?? .clear)
  }
}

struct ThemeColorControls: View {
  @Binding var preset: AppAccent
  private var preferences = AppearancePreferences()
  init(preset: Binding<AppAccent>) { _preset = preset }
  private func selection(_ hex: Binding<String>, default color: Color) -> Binding<Color> {
    Binding(
      get: { JournalPalette.color(hex.wrappedValue) ?? color },
      set: { if let value = JournalPalette.hex($0) { hex.wrappedValue = value } })
  }
  var body: some View {
    ColorPicker(
      "Custom accent", selection: selection(preferences.$accent, default: preset.color),
      supportsOpacity: false)
    ColorPicker(
      "Background",
      selection: selection(
        preferences.$background, default: Color(uiColor: .systemGroupedBackground)),
      supportsOpacity: false)
    ColorPicker(
      "Row background",
      selection: selection(
        preferences.$surface, default: Color(uiColor: .secondarySystemGroupedBackground)),
      supportsOpacity: false)
    ColorPicker(
      "Text", selection: selection(preferences.$text, default: .primary), supportsOpacity: false)
    if preferences.palette != JournalPalette() || preset != .purple {
      Button("Reset colors") {
        preferences.background = ""
        preferences.surface = ""
        preferences.text = ""
        preferences.accent = ""
        preset = .purple
      }
    }
  }
}

enum HomeIcon: String, CaseIterable {
  case classic = "Classic"
  case ocean = "Ocean"
  case grove = "Grove"
  case sunset = "Sunset"
  var asset: String? { self == .classic ? nil : "AppIcon" + rawValue }
  var preview: String { "Preview" + rawValue }
}

struct AppIconPicker: View {
  @State private var active = UIApplication.shared.alternateIconName
  @State private var changing = false
  @State private var error: String?
  var body: some View {
    JournalList {
      ForEach(HomeIcon.allCases, id: \.self) { icon in
        Button {
          guard !changing, active != icon.asset else { return }
          changing = true
          Task { @MainActor in
            defer {
              changing = false
              active = UIApplication.shared.alternateIconName
            }
            do { try await UIApplication.shared.setAlternateIconName(icon.asset) } catch {
              self.error = error.localizedDescription
            }
          }
        } label: {
          HStack(spacing: 12) {
            Image(icon.preview).resizable().frame(width: 44, height: 44).clipShape(
              RoundedRectangle(cornerRadius: 10))
            Text(icon.rawValue)
            Spacer()
            if active == icon.asset { Image(systemName: "checkmark").foregroundStyle(.tint) }
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(changing)
          .accessibilityAddTraits(active == icon.asset ? .isSelected : [])
      }
    }.navigationTitle("App icon")
      .onAppear { active = UIApplication.shared.alternateIconName }
      .alert(
        "Couldn’t change icon",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK") { error = nil }
      } message: {
        Text(error ?? "")
      }
  }
}
