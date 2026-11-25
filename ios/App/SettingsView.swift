import IntakeKit
import SwiftUI
import UniformTypeIdentifiers

struct JournalFile: FileDocument {
  static var readableContentTypes: [UTType] { [.data, .json, .commaSeparatedText] }
  var bytes: Data
  init(_ bytes: Data) { self.bytes = bytes }
  init(configuration: ReadConfiguration) throws {
    bytes = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: bytes)
  }
}
struct SettingsView: View {
  @EnvironmentObject var m: JournalModel
  @State var address = ""
  @State var name = ""
  @State var password = ""
  @State var register = false
  @State var supportsSignup = false
  @State var keepLocal = true
  @State var confirmDelete = false
  @State var importing = false
  @State var exporting = false
  @State var preview: [Record]?
  @State var file = JournalFile(Data())
  @State var exportName = "intake.json"
  @State var timezone = ""
  @State var boundary = 0
  @State var item: Record?
  var body: some View {
    NavigationStack {
      Form {
        Section("Sync") {
          if let b = m.state.binding {
            Text(b.username + " · " + b.origin).textSelection(.enabled)
            Text(
              m.syncStatus.isEmpty ? (m.signedIn ? "Connected" : "Sign in to sync") : m.syncStatus)
            if m.signedIn {
              Button("Sync now") { m.trigger() }.disabled(m.busy)
              Button("Sign out") { m.signout() }.disabled(m.busy)
            }
          }
          if !m.signedIn {
            TextField("HTTPS server", text: $address).keyboardType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Username", text: $name).textInputAutocapitalization(.never)
              .autocorrectionDisabled().textContentType(.username)
            SecureField("Password", text: $password).textContentType(
              register ? .newPassword : .password)
            if supportsSignup { Toggle("Create account", isOn: $register) }
            Button(register ? "Create account" : "Sign in") {
              m.authenticate(address, name, password, signup: register)
              password = ""
            }.disabled(address.isEmpty || name.isEmpty || password.isEmpty || m.busy)
            Button("Check signup availability") {
              Task {
                do {
                  supportsSignup = try await Server(address).canRegister()
                  if !supportsSignup { m.message = "Registration is unavailable on this server." }
                } catch { m.message = error.localizedDescription }
              }
            }.disabled(address.isEmpty || m.busy)
          }
          if let c = m.candidate {
            Text(
              "Sync this journal with \(c.profile.username) on \(c.server.origin.absoluteString)? Entries on this iPhone will be sent there."
            )
            Button("Sync this journal") { m.approveMerge() }.disabled(m.busy)
            Button("Cancel") { m.candidate = nil }
          }
        }
        if !m.state.conflicts.isEmpty {
          Section("Resolve conflicts") {
            ForEach(m.state.conflicts.keys.sorted(), id: \.self) { id in
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
        Section("Journal day") {
          Picker("Time zone", selection: $timezone) {
            ForEach(
              Array(Set(TimeZone.knownTimeZoneIdentifiers + [m.state.settings.timezone])).sorted(),
              id: \.self
            ) { Text($0) }
          }
          Stepper("Day starts at \(boundary):00", value: $boundary, in: 0...23)
          Button("Save settings") {
            m.updateSettings(Settings(timezone: timezone, day_start: boundary))
          }.disabled(m.busy)
          if let p = m.state.settingsConflict {
            Text("Server: \(p.timezone), \(p.day_start):00")
            Button("Use server settings") { m.change { try $0.preferences(p) } }
          }
        }
        Section("Items") {
          ForEach(m.state.visible(.item)) { r in
            Button(r.text("name") + (r.data["archived"] == .bool(true) ? " (archived)" : "")) {
              item = r
            }
          }
        }
        Section("Import and export") {
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
          Button("Import JSON or CSV") { importing = true }
          if let preview {
            Text(
              "\(preview.filter { $0.entity == .item }.count) items, \(preview.filter { $0.entity == .entry }.count) entries, \(preview.filter { $0.entity == .day }.count) days"
            )
            Button("Import these records") {
              if m.change({ try $0.applyImport(preview) }) { self.preview = nil }
            }
            Button("Cancel import") { self.preview = nil }
          }
          Button("Export JSON") {
            do { try prepare(Transfer.export(m.state), "intake.json") } catch {
              m.message = error.localizedDescription
            }
          }
          if m.signedIn {
            Button("Export Excel (.xls)") {
              Task {
                do { try await prepare(m.xls(), "intake.xls") } catch {
                  m.message = error.localizedDescription
                }
              }
            }
          }
        }
        if let b = m.state.binding {
          Section("Server account") {
            Toggle("Keep a local copy on this iPhone", isOn: $keepLocal)
            Button("Delete server account", role: .destructive) { confirmDelete = true }.disabled(
              !m.signedIn || m.busy
            )
            .confirmationDialog(
              "Delete \(b.username) on \(b.origin)?", isPresented: $confirmDelete,
              titleVisibility: .visible
            ) {
              Button("Permanently delete server account", role: .destructive) {
                m.deleteAccount(keepLocal: keepLocal)
              }
            } message: {
              Text(
                "Deletes the server journal and signs out all devices. "
                  + (keepLocal
                    ? "This iPhone keeps a local-only copy."
                    : "Also erases this journal and unsynced entries on this iPhone."))
            }
          }
        }
      }.navigationTitle("Settings")
        .onAppear {
          timezone = m.state.settings.timezone
          boundary = m.state.settings.day_start
          if address.isEmpty { address = m.state.binding?.origin ?? "" }
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
        .fileImporter(
          isPresented: $importing, allowedContentTypes: [.json, .commaSeparatedText, .plainText]
        ) { result in
          do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 5_000_000 else { throw Problem.message("File is too large.") }
            preview = try Transfer.decode(
              Data(contentsOf: url), csv: url.pathExtension.lowercased() == "csv")
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
