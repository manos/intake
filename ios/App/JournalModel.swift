import Foundation
import IntakeKit
import Network
import SwiftUI

@MainActor final class JournalModel: ObservableObject {
  @Published private(set) var state = JournalState()
  @Published private(set) var busy = false
  @Published private(set) var ready = false
  @Published private(set) var signedIn = false
  @Published private var presence = ServerPresence()
  var connectionBadge: ServerPresence.Badge? {
    presence.badge(server: state.binding?.key, signedIn: signedIn)
  }
  @Published var message: String?
  @Published var syncStatus = ""
  @Published var candidate: Candidate?
  @Published var undo: Record?
  var scope: String { (journal?.profile ?? "") + "|" + (state.binding?.key ?? "local") }
  struct Candidate: Identifiable {
    let id = UUID()
    let server: Server, profile: Profile, token: String, signup: Bool
  }
  private var file: URL?
  private var journal: Journal?
  private let network = NWPathMonitor()
  private var retry: Task<Void, Never>?, delay = 2
  private var syncTask: Task<Bool, Never>?
  private var foregroundTask: Task<Void, Never>?
  private var active = true, resync = false

  init() {
    open()
    network.pathUpdateHandler = { [weak self] path in
      let offline = path.status == .unsatisfied
      Task { @MainActor in
        guard let self else { return }
        self.presence.networkChanged(offline: offline)
        if !offline { self.trigger() }
      }
    }
    network.start(queue: DispatchQueue(label: "Intake.connectivity"))
  }
  func open() {
    do {
      let fm = FileManager.default
      let dir = try fm.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Journal", isDirectory: true)
      try fm.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete])
      let url = dir.appendingPathComponent("intake.sqlite3")
      file = url
      journal = try Journal(
        file: url, profile: UserDefaults.standard.string(forKey: "activeJournal") ?? "local")
      try refresh()
      ready = true
    } catch { message = error.localizedDescription }
  }
  private func refresh() throws {
    guard let journal else { throw Problem.message("Journal is unavailable.") }
    state = try journal.read()
    if let b = state.binding {
      signedIn = try DeviceSession.load(b.key) != nil
    } else {
      signedIn = false
    }
  }
  func lifecycle(_ foreground: Bool) {
    active = foreground
    if foreground {
      presence.invalidate()
      if !ready { open() }
      trigger()
    } else {
      retry?.cancel()
    }
  }
  private func foregroundWork(_ work: @escaping () async throws -> Void) {
    guard !busy else { return }
    busy = true
    foregroundTask = Task {
      defer {
        foregroundTask = nil
        busy = false
        if resync {
          resync = false
          trigger()
        }
      }
      do {
        try await work()
        try refresh()
      } catch { message = error.localizedDescription }
    }
  }
  func edit(_ row: Record) { change { try $0.put(row) } }
  func remove(_ r: Record) {
    var row = r
    row.deleted = true
    if change({ try $0.put(row) }) { undo = r }
  }
  func purge(_ id: String) { if change({ try $0.purge(id) }) { undo = nil } }
  @discardableResult func change(_ work: (Journal) throws -> Void) -> Bool {
    do {
      guard let journal else { throw Problem.message("Journal unavailable.") }
      try work(journal)
      try refresh()
      trigger()
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  func authenticate(_ address: String, _ name: String, _ password: String, signup: Bool) {
    foregroundWork {
      let server = try Server(address)
      let (profile, token) = try await server.authenticate(
        username: name, password: password, signup: signup, timezone: self.state.settings.timezone)
      let c = Candidate(server: server, profile: profile, token: token, signup: signup)
      if self.state.binding == nil && self.state.hasLocalData {
        self.candidate = c
      } else {
        try await self.link(c)
      }
    }
  }
  private func link(_ c: Candidate) async throws {
    guard let file, var target = journal else { throw Problem.message("Journal unavailable.") }
    let binding = IntakeKit.Binding(
      origin: c.server.origin.absoluteString, account: c.profile.id, username: c.profile.username)
    if state.binding?.key != binding.key {
      var found: Journal?
      for id in try target.profiles() {
        let other = try Journal(file: file, profile: id)
        if try other.read().binding?.key == binding.key {
          found = other
          break
        }
      }
      if let found {
        target = found
      } else if state.binding != nil {
        target = try Journal(file: file, profile: UUID().uuidString)
      }
    }
    if let source = journal, source.profile != target.profile, state.binding == nil,
      state.hasLocalData
    {
      guard approvedPopulatedLink else {
        candidate = c
        return
      }
      let (rows, cursor) = try await c.server.snapshot(token: c.token, account: c.profile.id)
      try target.link(
        binding, remote: rows, cursor: cursor, settings: c.profile.settings, recovering: true)
      try target.absorb(local: source.profile)
    }
    if try target.read().binding == nil {
      let (rows, cursor) = try await c.server.snapshot(token: c.token, account: c.profile.id)
      // The journal may have received its first edit while the download was running.
      if target.profile == journal?.profile, candidate == nil, !approvedPopulatedLink,
        try target.read().hasLocalData
      {
        candidate = c
        return
      }
      try target.link(
        binding, remote: rows, cursor: cursor, settings: c.profile.settings, newAccount: c.signup)
      let linked = try target.read()
      if c.signup, linked.settingsConflict != nil {
        let settings = linked.settings
        try await c.server.settings(settings, token: c.token, account: c.profile.id)
        try target.preferences(settings)
      }
    }
    try DeviceSession.set(binding.key, c.token)
    journal = target
    UserDefaults.standard.set(target.profile, forKey: "activeJournal")
    undo = nil
    syncStatus = ""
    try refresh()
    resync = true
  }
  private var approvedPopulatedLink = false
  func approveMerge() {
    guard !busy, let c = candidate else { return }
    candidate = nil
    foregroundWork {
      self.approvedPopulatedLink = true
      defer { self.approvedPopulatedLink = false }
      try await self.link(c)
    }
  }
  /// The refresh gesture joins the same task as automatic sync so its spinner
  /// covers the final change page and any queued writes.
  func pullToSync() async -> Bool {
    let requestedScope = scope
    if let foregroundTask { await foregroundTask.value }
    guard requestedScope == scope, !Task.isCancelled else { return false }
    guard let task = syncTask ?? trigger() else { return false }
    let completed = await task.value
    return completed && requestedScope == scope && !Task.isCancelled
  }
  @discardableResult func trigger() -> Task<Bool, Never>? {
    guard active, signedIn, candidate == nil, state.deletionChoice == nil, let journal,
      let b = state.binding
    else { return nil }
    if !state.maySync(at: .now), let until = state.retryAfter {
      scheduleRetry(until.timeIntervalSinceNow)
      return nil
    }
    if busy {
      resync = true
      return syncTask
    }
    retry?.cancel()
    busy = true
    let generation = presence.generation
    let task = Task {
      var wait: Int?
      var completed = false
      do {
        guard let token = try DeviceSession.load(b.key) else {
          throw ServerError.response(401, nil)
        }
        let server = try Server(b.origin)
        let profile = try await server.me(token, account: b.account)
        presence.report(server: b.key, generation: generation, reachable: true)
        if state.settingsConflict == nil && state.settings != profile.settings {
          try journal.preferences(profile.settings)
        }
        syncStatus = "Syncing…"
        while active {
          let old = try journal.read()
          if let id = old.purges.first {
            try await server.deleteItem(id, token: token, account: b.account)
            try journal.acknowledgePurge(id)
            continue
          }
          let ops = try journal.batch()
          do {
            let page = try await server.pull(
              journal.requestBody(ops), token: token, account: b.account)
            guard Set(page.results.map(\.id)) == Set(ops.map(\.id)),
              !page.has_more || page.cursor > old.cursor
            else { throw ServerError.invalid }
            try journal.accept(page)
            if try !page.has_more && journal.batch().isEmpty && journal.read().purges.isEmpty {
              completed = true
              break
            }
          } catch ServerError.cursorReset {
            let (rows, cursor) = try await server.snapshot(token: token, account: b.account)
            try journal.link(
              b, remote: rows, cursor: cursor, settings: profile.settings, recovering: true)
          }
        }
        try refresh()
        completed = completed && !state.incomplete
        syncStatus = completed ? "Synced" : "Sync incomplete"
        delay = 2
      } catch ServerError.response(401, _) {
        completed = false
        try? DeviceSession.set(b.key, nil)
        signedIn = false
        syncStatus = "Sign in to sync"
      } catch {
        completed = false
        syncStatus = error.localizedDescription
        if error is URLError {
          presence.report(server: b.key, generation: generation, reachable: false)
        } else if case ServerError.response(500...599, _) = error {
          presence.report(server: b.key, generation: generation, reachable: false)
        }
        if case ServerError.response(429, let seconds) = error {
          wait = seconds ?? 60
          try? journal.postpone(until: Date().addingTimeInterval(Double(max(1, wait ?? 60))))
        } else {
          wait = delay
          delay = min(120, delay * 2)
        }
      }
      if active { presence.finishedSync(server: b.key, succeeded: completed) }
      syncTask = nil
      busy = false
      try? refresh()
      if let wait, active {
        resync = false
        scheduleRetry(Double(wait))
      } else if resync {
        resync = false
        trigger()
      }
      return completed && active
    }
    syncTask = task
    return task
  }
  /// Refresh only while the banner is visible and the last sync succeeded.
  /// Failed connections already use the sync worker's retry schedule.
  func refreshIdleConnection() {
    if active, !busy, connectionBadge == .connected || connectionBadge == .syncFailed,
      syncStatus == "Synced" || syncStatus == "Sync incomplete"
    {
      trigger()
    }
  }
  private func scheduleRetry(_ seconds: Double) {
    retry?.cancel()
    retry = Task {
      try? await Task.sleep(for: .seconds(max(1, min(seconds, 86400))))
      if !Task.isCancelled { self.trigger() }
    }
  }
  func reconcile() {
    guard let b = state.binding, let journal, state.maySync(at: .now), state.deletionChoice == nil
    else { return }
    foregroundWork {
      guard let token = try DeviceSession.load(b.key) else { throw ServerError.response(401, nil) }
      let server = try Server(b.origin)
      let p = try await server.me(token, account: b.account)
      let (rows, cursor) = try await server.snapshot(token: token, account: b.account)
      try journal.link(b, remote: rows, cursor: cursor, settings: p.settings, recovering: true)
      self.resync = true
    }
  }
  func signout() {
    guard let b = state.binding else { return }
    foregroundWork {
      let token = try DeviceSession.load(b.key)
      try DeviceSession.set(b.key, nil)
      self.signedIn = false
      self.syncStatus = "Signed out"
      if let token { try? await Server(b.origin).logout(token: token, account: b.account) }
    }
  }
  func deleteAccount(keepLocal: Bool) {
    guard let b = state.binding, let journal else { return }
    foregroundWork {
      guard let token = try DeviceSession.load(b.key) else {
        throw Problem.message("Sign in to delete this server account.")
      }
      let server = try Server(b.origin)
      guard try await server.canDelete() else {
        throw Problem.message("Update this Intake server to enable account deletion.")
      }
      _ = try await server.me(token, account: b.account)
      try journal.deletionAttempt(keepLocal: keepLocal)
      try self.refresh()
      try await server.deleteAccount(token: token, account: b.account)
      try journal.disconnectAfterDeletion(keepLocal: keepLocal)
      try DeviceSession.set(b.key, nil)
      self.undo = nil
      self.syncStatus = ""
    }
  }
  func finishOnPhone(keepLocal: Bool) {
    guard let b = state.binding, state.deletionChoice != nil, let journal else { return }
    foregroundWork {
      try journal.disconnectAfterDeletion(keepLocal: keepLocal)
      try DeviceSession.set(b.key, nil)
      self.undo = nil
      self.syncStatus = ""
    }
  }
  func updateSettings(_ p: Settings) {
    guard let journal else { return }
    if let b = state.binding {
      foregroundWork {
        guard let token = try DeviceSession.load(b.key) else {
          throw Problem.message("Sign in to update this account's settings.")
        }
        try await Server(b.origin).settings(p, token: token, account: b.account)
        try journal.preferences(p)
      }
    } else {
      change { try $0.preferences(p) }
    }
  }
  func xls() async throws -> Data {
    guard let b = state.binding, let token = try DeviceSession.load(b.key) else {
      throw Problem.message("Connect to a server for Excel export.")
    }
    return try await Server(b.origin).spreadsheet(
      Transfer.export(state), token: token, account: b.account)
  }
}
