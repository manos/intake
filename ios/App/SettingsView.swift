import IntakeKit
import SwiftUI
import UniformTypeIdentifiers

private struct ItemOrderEditor: View {
  @EnvironmentObject private var model: JournalModel
  @Environment(\.dismiss) private var dismiss
  @State private var rows: [Record]
  @State private var openingOrder: [String]
  init(items: [Record]) {
    _rows = State(initialValue: items)
    _openingOrder = State(initialValue: items.map(\.id))
  }
  var body: some View {
    NavigationStack {
      JournalList {
        ForEach(rows) { item in
          HStack {
            Circle().fill(itemColor(item)).frame(width: 12, height: 12)
            Text(item.text("name"))
            if item.data["archived"] == .bool(true) {
              Text("Archived").font(.caption).foregroundStyle(.secondary)
            }
          }
        }.onMove { source, destination in rows.move(fromOffsets: source, toOffset: destination) }
      }.environment(\.editMode, .constant(.active))
        .navigationTitle("Sort items").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              let ids = rows.map(\.id)
              if ids == openingOrder
                || model.change({ try $0.reorderItems(ids, replacing: openingOrder) })
              {
                dismiss()
              }
            }
          }
        }
    }
  }
}

struct JournalFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  static var writableContentTypes: [UTType] { [.json, UTType(filenameExtension: "xls") ?? .data] }
  var bytes: Data
  init(_ bytes: Data) { self.bytes = bytes }
  init(configuration: ReadConfiguration) throws {
    bytes = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: bytes)
  }
}
enum AppAccent: String, CaseIterable {
  case purple = "Purple"
  case blue = "Blue"
  case teal = "Teal"
  case green = "Green"
  case orange = "Orange"
  case pink = "Pink"
  case graphite = "Graphite"

  var color: Color {
    switch self {
    case .purple: .purple
    case .blue: .blue
    case .teal: .teal
    case .green: .green
    case .orange: .orange
    case .pink: .pink
    case .graphite: .primary
    }
  }
}

struct SettingsView: View {
  private let guide = URL(
    string: "https://github.com/manos/intake/blob/main/README.md#native-iphone-app")!
  @SwiftUI.Binding var accent: AppAccent
  private var appearance = AppearancePreferences()
  init(accent: SwiftUI.Binding<AppAccent>) { _accent = accent }
  @EnvironmentObject var m: JournalModel
  @State var address = ""
  @State var name = ""
  @State var password = ""
  @State private var connecting = false
  @State var register = false
  @State var supportsSignup = false
  @State var importing = false
  @State var exporting = false
  @State var preview: [Record]?
  @State var previewScope = ""
  @State var file = JournalFile(Data())
  @State var exportName = "intake.json"
  @State var timezone = ""
  @State var boundary = 0
  @State var item: Record?
  @State private var addingItem = false
  @State private var sorting = false
  var body: some View {
    NavigationStack {
      JournalForm {
        Section("Items") {
          if m.display.items.count > 1 {
            Button("Sort items", systemImage: "arrow.up.arrow.down") { sorting = true }
          }
          Button("Add item", systemImage: "plus") { addingItem = true }
          ForEach(m.display.items) { r in
            Button(r.text("name") + (r.data["archived"] == .bool(true) ? " (archived)" : "")) {
              item = r
            }
          }
        }
        Section("Sync") {
          if let b = m.state.binding {
            Text(b.username + " · " + b.address).textSelection(.enabled)
            Text(
              m.signedIn && !m.state.connectionEnabled
                ? "Disconnected"
                : m.syncStatus.isEmpty
                  ? (m.signedIn ? "Connected" : "Sign in to sync") : m.syncStatus)
            if m.signedIn {
              if m.state.connectionEnabled {
                Button("Sync now") { m.trigger() }.disabled(m.busy)
              } else {
                Button("Reconnect") { m.toggleConnection() }.disabled(!m.canToggleConnection)
              }
              Button("Sign out") { m.signout() }.disabled(m.busy)
            }
          } else if !connecting && m.candidate == nil {
            Button("Connect to server", systemImage: "icloud") { connecting = true }
          }
          if !m.signedIn && (m.state.binding != nil || connecting) && m.candidate == nil {
            HStack(spacing: 3) {
              Text("Your self-hosted Intake server")
              Link("(docs)", destination: guide)
            }.font(.footnote)
            TextField("Server address", text: $address).keyboardType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Username", text: $name).textInputAutocapitalization(.never)
              .autocorrectionDisabled().textContentType(.username)
            SecureField("Password", text: $password).textContentType(
              register ? .newPassword : .password)
            if supportsSignup { Toggle("Create account", isOn: $register) }
            Button(register ? "Create account" : (m.state.binding == nil ? "Connect" : "Sign in")) {
              m.authenticate(address, name, password, signup: register)
              password = ""
            }.disabled(address.isEmpty || name.isEmpty || password.isEmpty || m.busy)
            Button("Check signup availability") {
              Task {
                do {
                  supportsSignup = try await Server.discover(address, purpose: .availability)
                    .canRegister()
                  if !supportsSignup { m.message = "Registration is unavailable on this server." }
                } catch { m.message = error.localizedDescription }
              }
            }.disabled(address.isEmpty || m.busy)
            if m.state.binding == nil {
              Button("Cancel") {
                password = ""
                register = false
                connecting = false
              }.disabled(m.busy)
            }
          }
          if let c = m.candidate {
            Text(
              "Sync this journal with \(c.profile.username) on \(c.server.origin.absoluteString)? Entries on this iPhone will be sent there."
            )
            Button("Sync this journal") { m.approveMerge() }.disabled(m.busy)
            Button("Cancel") {
              m.candidate = nil
              connecting = false
            }
          }
          if m.signedIn || (!connecting && m.state.binding == nil) {
            Link(destination: guide) {
              Label("Setup and sync guide", systemImage: "book")
            }
          }
          Toggle(isOn: .init(get: { m.state.keepLocalCopy }, set: m.setKeepLocalCopy)) {
            Text("Keep a local copy")
            Text("Keep this journal on your iPhone if you delete its server account.").font(
              .caption)
          }.disabled(m.state.deletionChoice != nil || m.busy)
          Toggle(isOn: .init(get: { m.backupEnabled }, set: m.setBackupEnabled)) {
            Text("Back up to iCloud")
            Text("Include this iPhone’s journals in device backups when iCloud Backup is on.").font(
              .caption)
          }
          if let account = m.state.binding { ServerDeletionActions(account: account) }
          ForEach(m.display.competingDays.keys.sorted(), id: \.self) { day in
            Text("Choose the Daily Journal entry for \(day)").font(.headline)
            ForEach(m.display.competingDays[day] ?? []) { r in
              Button("Keep: \(r.text("note"))\(r.data["zero"] == .bool(true) ? " (zero day)" : "")")
              {
                m.change { try $0.resolveDay(day, using: r) }
              }
            }
          }
          if !m.state.conflicts.isEmpty {
            Text("Resolve conflicts").font(.headline)
            ForEach(
              m.state.conflicts.keys.filter { id in
                guard let r = m.state.records[id], r.entity == .day else { return true }
                return m.display.competingDays[r.text("date")] == nil
              }.sorted(), id: \.self
            ) { id in
              let conflict = m.state.conflicts[id]
              Text(conflict?.reason ?? "Different versions")
              Text("This phone: " + summary(m.state.records[id]))
              Text("Server: " + summary(conflict?.remote))
              Button("Keep this phone’s version") {
                m.change { try $0.resolve(id, keepLocal: true) }
              }
              Button("Use server version") { m.change { try $0.resolve(id, keepLocal: false) } }
            }
          }
        }
        Section("Journal Day") {
          Picker("Time zone", selection: $timezone) {
            ForEach(
              Array(Set(TimeZone.knownTimeZoneIdentifiers + [m.state.settings.timezone])).sorted(),
              id: \.self
            ) { Text($0) }
          }.pickerStyle(.navigationLink)
          Stepper("Day starts at \(boundary):00", value: $boundary, in: 0...23)
          Button("Save settings") {
            m.updateSettings(Settings(timezone: timezone, day_start: boundary))
          }.disabled(m.busy || (m.state.binding != nil && !m.state.connectionEnabled))
          if let p = m.state.settingsConflict {
            Text("Server: \(p.timezone), \(p.day_start):00")
            Button("Use server settings") { m.change { try $0.preferences(p) } }
          }
        }
        Section("Appearance") {
          NavigationLink {
            JournalList {
              ForEach(AppAccent.allCases, id: \.self) { choice in
                Button {
                  appearance.accent = ""
                  accent = choice
                } label: {
                  HStack {
                    Circle().fill(choice.color).frame(width: 16, height: 16)
                    Text(choice.rawValue)
                    Spacer()
                    if choice == accent && appearance.accent.isEmpty {
                      Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                  }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                  .accessibilityAddTraits(
                    choice == accent && appearance.accent.isEmpty ? .isSelected : [])
              }
            }.navigationTitle("Accent color")
          } label: {
            LabeledContent("Accent color") {
              Circle().fill(JournalPalette.color(appearance.accent) ?? accent.color).frame(
                width: 14, height: 14)
              Text(appearance.accent.isEmpty ? accent.rawValue : "Custom")
            }
          }
          ThemeColorControls(preset: $accent)
          if UIApplication.shared.supportsAlternateIcons {
            NavigationLink("App icon") { AppIconPicker() }
          }
        }
        Section("Import and Export") {
          ForEach(m.state.importConflicts.keys.sorted(), id: \.self) { id in
            Text("This journal: " + summary(m.state.records[id]))
            Text("Imported: " + summary(m.state.importConflicts[id]))
            Button("Keep journal version") {
              m.change { try $0.resolveImport(id, useImported: false) }
            }
            Button("Use imported version") {
              m.change { try $0.resolveImport(id, useImported: true) }
            }
          }
          Button("Import JSON backup") {
            preview = nil
            previewScope = m.scope
            importing = true
          }
          if let preview {
            Text(
              "\(preview.filter { $0.entity == .item }.count) items, \(preview.filter { $0.entity == .entry }.count) entries, \(preview.filter { $0.entity == .day }.count) days"
            )
            Button("Import these records") {
              if m.change({ try $0.applyImport(preview, expectedScope: previewScope) }) {
                self.preview = nil
              }
            }
            Button("Cancel import") { self.preview = nil }
          }
          Button("Export JSON") {
            do { try prepare(Transfer.export(m.state), "intake.json") } catch {
              m.message = error.localizedDescription
            }
          }
          if m.signedIn && m.state.connectionEnabled {
            Button("Export Excel (.xls)") {
              Task {
                do { try await prepare(m.xls(), "intake.xls") } catch {
                  m.message = error.localizedDescription
                }
              }
            }
          }
        }
      }.navigationTitle("Settings")
        .onAppear {
          timezone = m.state.settings.timezone
          boundary = m.state.settings.day_start
          if address.isEmpty { address = m.state.binding?.address ?? "" }
          name = m.state.binding?.username ?? name
        }
        .onChange(of: m.state.settings) { _, s in
          timezone = s.timezone
          boundary = s.day_start
        }
        .onChange(of: address) { _, _ in
          supportsSignup = false
          register = false
        }
        .sheet(item: $item) { ItemEditor(row: $0) }
        .sheet(isPresented: $addingItem) { ItemEditor(row: nil) }
        .sheet(isPresented: $sorting) { ItemOrderEditor(items: m.display.items) }
        .fileImporter(
          isPresented: $importing, allowedContentTypes: [.json]
        ) { result in
          do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 5_000_000 else { throw Problem.message("File is too large.") }
            preview = try Transfer.decode(Data(contentsOf: url))
          } catch { m.message = error.localizedDescription }
        }
        .fileExporter(
          isPresented: $exporting, document: file,
          contentType: exportName.hasSuffix(".json")
            ? .json : (UTType(filenameExtension: "xls") ?? .data), defaultFilename: exportName
        ) { result in
          if case .failure(let error) = result { m.message = error.localizedDescription }
        }
    }
  }
  func prepare(_ bytes: Data, _ filename: String) throws {
    file = JournalFile(bytes)
    exportName = filename
    exporting = true
  }
  func summary(_ row: Record?) -> String {
    guard let row else { return "No record" }
    if row.deleted { return "Deleted" }
    return row.data.keys.sorted().map {
      "\($0): \(row.text($0).isEmpty ? String(describing:row.data[$0]!) : row.text($0))"
    }.joined(separator: "\n")
  }
}

private struct ServerDeletionActions: View {
  let account: IntakeKit.Binding
  @EnvironmentObject private var m: JournalModel
  @State private var confirmDelete = false
  init(account: IntakeKit.Binding) { self.account = account }
  var body: some View {
    if let choice = m.state.deletionChoice {
      Text(
        "The server’s deletion response was not confirmed. You can finish on this iPhone without sending another request."
      )
      Button(
        choice ? "Disconnect and keep this journal" : "Disconnect and erase this journal",
        role: choice ? nil : .destructive
      ) {
        m.finishOnPhone(keepLocal: choice)
      }.disabled(m.busy)
      Button("Stay connected") { m.change { try $0.deletionAttempt(keepLocal: nil) } }
        .disabled(m.busy)
    }
    Button("Delete server account", role: .destructive) { confirmDelete = true }
      .disabled(!m.signedIn || !m.state.connectionEnabled || m.busy)
      .confirmationDialog(
        "Delete \(account.username) on \(account.origin)?",
        isPresented: $confirmDelete, titleVisibility: .visible
      ) {
        Button("Permanently delete server account", role: .destructive) { m.deleteAccount() }
      } message: {
        Text(
          "Deletes the server journal and signs out all devices. "
            + (m.state.keepLocalCopy
              ? "This iPhone keeps a local-only copy."
              : "Also erases this journal and unsynced entries on this iPhone."))
      }
  }
}
