import Foundation
import GRDB

/// One transactional snapshot per journal. The web client uses the same unit of
/// atomicity. The database and schema migrations are independent of server availability.
public final class Journal {
  private let db: DatabaseQueue
  public let profile: String
  public init(file: URL? = nil, profile: String = "local") throws {
    self.profile = profile
    db = try file.map { try DatabaseQueue(path: $0.path) } ?? DatabaseQueue()
    var migrations = DatabaseMigrator()
    migrations.registerMigration("journal-v1") { d in
      try d.execute(
        sql: "CREATE TABLE journals (profile TEXT PRIMARY KEY NOT NULL, state BLOB NOT NULL)")
    }
    try migrations.migrate(db)
  }
  private func load(_ d: Database) throws -> JournalState {
    guard
      let data = try Data.fetchOne(
        d, sql: "SELECT state FROM journals WHERE profile = ?", arguments: [profile])
    else { return JournalState() }
    return try JSONDecoder().decode(JournalState.self, from: data)
  }
  public func read() throws -> JournalState { try db.read(load) }
  public func scope() throws -> String { profile + "|" + (try read().binding?.key ?? "local") }
  public func profiles() throws -> [String] {
    try db.read { try String.fetchAll($0, sql: "SELECT profile FROM journals ORDER BY profile") }
  }
  private func change<T>(_ body: (inout JournalState) throws -> T) throws -> T {
    try db.write { d in
      var s = try load(d)
      let result = try body(&s)
      try d.execute(
        sql: "INSERT OR REPLACE INTO journals(profile,state) VALUES (?,?)",
        arguments: [profile, try JSONEncoder().encode(s)])
      return result
    }
  }
  private func save(_ row: Record, _ s: inout JournalState) {
    s.records[row.id] = row
    if s.binding != nil {
      s.incomplete = true
      if s.conflicts[row.id] != nil { return }
      // Only supersede edits that could not yet have reached the server.
      let base =
        s.pending.first(where: { $0.record_id == row.id })?.base_version ?? s.baseline[row.id]?
        .version ?? 0
      s.pending.removeAll { $0.record_id == row.id && s.frozen[$0.id] == nil }
      if row.deleted, s.baseline[row.id] == nil,
        !s.pending.contains(where: { $0.record_id == row.id })
      {
        return
      }
      s.pending.append(Operation(row, base: base))
    }
  }
  public func put(_ row: Record) throws {
    try change { s in
      if let existing = s.records[row.id], existing.version != row.version {
        throw Problem.message(
          "This record changed while you were editing. Reopen it to see the current version.")
      }
      if s.records[row.id]?.purged == true || s.purges.contains(row.id) {
        throw Problem.message("Item was permanently deleted.")
      }
      if !row.deleted {
        try Transfer.validate(row)
        if row.entity == .entry && s.records[row.text("item_id")]?.entity != .item {
          throw Problem.message("This item is unavailable.")
        }
        if row.entity == .entry && s.records[row.text("item_id")]?.deleted == true {
          throw Problem.message("This item was deleted.")
        }
      }
      self.save(row, &s)
    }
  }
  public func preferences(_ settings: Settings) throws {
    try change {
      $0.settings = settings
      $0.customized = true
      $0.settingsConflict = nil
    }
  }
  public func applyImport(_ rows: [Record], expectedScope: String? = nil) throws {
    try change { s in
      if let expectedScope, expectedScope != profile + "|" + (s.binding?.key ?? "local") {
        throw Problem.message(
          "The active journal changed. Reopen the import in its original journal.")
      }
      try mergeRows(rows, &s)
    }
  }
  private func mergeRows(_ rows: [Record], _ s: inout JournalState) throws {
    let terminal = Set(s.records.values.filter(\.purged).map(\.id)).union(s.purges)
    let parents = Set((s.visible(.item) + rows.filter { $0.entity == .item }).map(\.id))
    for var r in rows {
      try Transfer.validate(r)
      if terminal.contains(r.id) || terminal.contains(r.text("item_id")) { continue }
      guard r.entity != .entry || parents.contains(r.text("item_id")) else {
        throw Problem.message("Import the item referenced by \(r.text("item_name")) first.")
      }
      if r.entity == .day,
        let existing = s.visible(.day).first(where: { $0.text("date") == r.text("date") })
      {
        r.id = existing.id
      }
      if let old = s.records[r.id] {
        if old.purged || old.equivalent(r) { continue }
        // Import is not a server response. Never manufacture a server revision.
        s.importConflicts[r.id] = r
        continue
      }
      save(r, &s)
    }
  }
  /// Merge into a cached account without replacing its baseline, cursor or outstanding writes.
  /// The standalone copy stays intact if the app stops before switching the active profile.
  public func absorb(local source: String) throws {
    try db.write { d in
      guard source != profile,
        let bytes = try Data.fetchOne(
          d, sql: "SELECT state FROM journals WHERE profile = ?", arguments: [source])
      else { return }
      let local = try JSONDecoder().decode(JournalState.self, from: bytes)
      guard local.binding == nil else {
        throw Problem.message("Cannot transfer another server account's journal.")
      }
      var dest = try load(d)
      try mergeRows(local.visible(.item) + local.visible(.entry) + local.visible(.day), &dest)
      for (id, row) in local.importConflicts where dest.records[id]?.purged != true {
        dest.importConflicts[id] = row
      }
      if local.customized, local.settings != dest.settings {
        dest.settingsConflict = dest.settings
        dest.settings = local.settings
        dest.customized = true
      }
      try d.execute(
        sql: "UPDATE journals SET state = ? WHERE profile = ?",
        arguments: [try JSONEncoder().encode(dest), profile])
    }
  }
  public func resolveImport(_ id: String, useImported: Bool) throws {
    try change { s in
      guard let row = s.importConflicts.removeValue(forKey: id) else { return }
      if useImported { save(row, &s) }
    }
  }
  private func clearPending(_ id: String, _ s: inout JournalState) {
    for o in s.pending where o.record_id == id { s.frozen[o.id] = nil }
    s.pending.removeAll { $0.record_id == id }
    s.conflicts[id] = nil
  }
  private func eraseItem(_ id: String, _ s: inout JournalState) {
    let children = Set(
      (Array(s.records.values) + Array(s.baseline.values) + Array(s.importConflicts.values)).filter
      {
        $0.entity == .entry && $0.text("item_id") == id
      }.map(\.id))
    for key in children.union([id]) {
      clearPending(key, &s)
      s.records[key] = nil
      s.baseline[key] = nil
      s.importConflicts[key] = nil
    }
  }
  public func purge(_ id: String) throws {
    try change { s in
      guard s.records[id]?.entity == .item else { throw Problem.message("Item is unavailable.") }
      eraseItem(id, &s)
      if s.binding != nil, !s.purges.contains(id) {
        var tomb = Record(.item, id: id, data: [:])
        tomb.deleted = true
        s.records[id] = tomb
        s.purges.append(id)
        s.incomplete = true
      }
    }
  }
  public func acknowledgePurge(_ id: String) throws {
    try change { $0.purges.removeAll { $0 == id } }
  }
  public func link(
    _ binding: Binding, remote: [Record], cursor: Int, settings: Settings, newAccount: Bool = false,
    recovering: Bool = false
  ) throws {
    try change { s in
      guard s.binding == nil || s.binding?.key == binding.key else {
        throw Problem.message("Choose a separate journal for this account.")
      }
      var latest: [String: Record] = [:]
      for r in remote where (latest[r.id]?.version ?? -1) <= r.version { latest[r.id] = r }
      var locals = s.records
      let localTombs = locals.filter { $0.value.entity == .item && $0.value.purged }
      let purgedItems = Set(latest.values.filter { $0.entity == .item && $0.purged }.map(\.id))
        .union(localTombs.keys)
        .union(s.purges)
      locals = locals.filter {
        !purgedItems.contains($0.key) && !purgedItems.contains($0.value.text("item_id"))
      }
      let oldBase = s.baseline
      let oldPending = s.pending
      let oldFrozen = s.frozen
      let oldConflicts = s.conflicts
      s.records = latest
      s.baseline = latest
      s.cursor = cursor
      s.binding = binding
      s.conflicts.removeAll()
      s.pending.removeAll()
      s.frozen.removeAll()
      for var local in locals.values.sorted(by: { $0.entity == .item && $1.entity != .item }) {
        if local.entity == .day, latest[local.id] == nil {
          let sameDay = latest.values.filter {
            $0.entity == .day && !$0.deleted && $0.text("date") == local.text("date")
          }
          if sameDay.count == 1 { local.id = sameDay[0].id }
          if sameDay.count > 1 {
            s.records[local.id] = local
            s.conflicts[local.id] = Conflict(
              remote: nil,
              reason: "Multiple server day notes share this date. Compare them before saving.")
            continue
          }
        }
        let server = latest[local.id]
        if server?.purged == true || local.purged { continue }
        if let server, server.equivalent(local) { continue }
        if recovering, let server,
          oldConflicts[local.id] != nil || oldBase[local.id]?.equivalent(server) != true
        {
          s.records[local.id] = local
          s.conflicts[local.id] = Conflict(
            remote: server, reason: "This copy differs from restored server history.")
        } else if recovering, server == nil,
          oldBase[local.id] != nil || oldConflicts[local.id] != nil
            || oldPending.contains(where: { $0.record_id == local.id && oldFrozen[$0.id] != nil })
        {
          s.records[local.id] = local
          s.conflicts[local.id] = Conflict(
            remote: nil, reason: "Missing after server restore. Recover this copy?")
        } else if let server, oldBase[local.id]?.equivalent(server) != true {
          s.records[local.id] = local
          s.conflicts[local.id] = Conflict(
            remote: server, reason: "Both journals contain different versions.")
        } else if !local.deleted || server != nil {
          save(local, &s)
        }
      }
      for key in purgedItems {
        eraseItem(key, &s)
        if let tomb = latest[key], tomb.purged {
          s.records[key] = tomb
          s.baseline[key] = tomb
        } else if let tomb = localTombs[key] {
          s.records[key] = tomb
          if !s.purges.contains(key) { s.purges.append(key) }
        }
      }
      if s.customized, s.settings != settings {
        s.settingsConflict = settings
      } else {
        s.settings = settings
      }
      s.incomplete = !s.pending.isEmpty || !s.conflicts.isEmpty || !s.purges.isEmpty
    }
  }
  public func batch() throws -> [Operation] {
    try change { s in
      var result: [Operation] = []
      var seen = Set<String>()
      var bytes = 128
      let ambiguous = s.competingDays
      if !s.purges.isEmpty { return [] }
      for var o in s.pending {
        guard seen.insert(o.record_id).inserted, s.conflicts[o.record_id] == nil else { continue }
        if o.entity == .day && ambiguous[o.data["date"]?.text ?? ""] != nil { continue }
        if o.entity == .entry, !o.deleted, let parent = o.data["item_id"]?.text,
          s.baseline[parent]?.entity != .item
        {
          continue
        }
        if let data = s.frozen[o.id] { o = try JSONDecoder().decode(Operation.self, from: data) }
        let data = try s.frozen[o.id] ?? JSONEncoder().encode(o)
        if result.count == 500 || bytes + data.count + 1 >= 3 * 1024 * 1024 { break }
        bytes += data.count + 1
        s.frozen[o.id] = data
        result.append(o)
      }
      return result
    }
  }
  public func requestBody(_ batch: [Operation]) throws -> Data {
    let s = try read()
    var body = Data("{\"cursor\":\(s.cursor),\"operations\":[".utf8)
    for (i, o) in batch.enumerated() {
      guard let bytes = s.frozen[o.id] else {
        throw Problem.message("Journal changed; retry sync.")
      }
      if i > 0 { body.append(44) }
      body.append(bytes)
    }
    body.append(contentsOf: "]}".utf8)
    return body
  }
  public func accept(_ page: Page) throws {
    try change { s in
      for r in page.results {
        guard let o = s.pending.first(where: { $0.id == r.id }) else { continue }
        if r.status == "applied", let row = r.record {
          s.pending.removeAll { $0.id == o.id }
          s.frozen[o.id] = nil
          s.baseline[row.id] = row
          if let next = s.pending.firstIndex(where: { $0.record_id == row.id }) {
            s.pending[next].base_version = row.version
          } else {
            s.records[row.id] = row
          }
        } else {
          s.conflicts[o.record_id] = Conflict(
            remote: r.record ?? s.baseline[o.record_id], reason: r.message ?? r.status)
        }
      }
      for row in page.changes {
        guard row.version >= (s.baseline[row.id]?.version ?? 0) else { continue }
        if s.purges.contains(row.id) || s.purges.contains(row.text("item_id")) { continue }
        if row.purged {
          if row.entity == .item { eraseItem(row.id, &s) } else { clearPending(row.id, &s) }
        }
        s.baseline[row.id] = row
        if !s.pending.contains(where: { $0.record_id == row.id }), s.conflicts[row.id] == nil {
          s.records[row.id] = row
        } else if s.conflicts[row.id] != nil {
          if row.version >= (s.conflicts[row.id]?.remote?.version ?? 0) {
            s.conflicts[row.id]?.remote = row
          }
        }
      }
      s.cursor = page.cursor
      s.incomplete =
        page.has_more || !s.pending.isEmpty || !s.conflicts.isEmpty || !s.purges.isEmpty
    }
  }
  public func resolve(_ id: String, keepLocal: Bool) throws {
    try change { s in
      guard let conflict = s.conflicts[id] else { return }
      clearPending(id, &s)
      s.baseline[id] = conflict.remote
      if keepLocal, let row = s.records[id] {
        save(row, &s)
      } else {
        s.records[id] = conflict.remote
      }
    }
  }
  public func resolveDay(_ day: String, using choice: Record) throws {
    try change { s in
      guard let rows = s.competingDays[day], rows.contains(where: { $0.id == choice.id }) else {
        throw Problem.message("Day notes changed. Review them again.")
      }
      let existing = rows.filter { s.baseline[$0.id] != nil }
      let winner =
        existing.first(where: { $0.id == choice.id })?.id ?? existing.first?.id ?? choice.id
      for var r in rows {
        clearPending(r.id, &s)
        if r.id != winner {
          if let base = s.baseline[r.id] {
            r = base
            r.deleted = true
            save(r, &s)
          } else {
            s.records[r.id] = nil
          }
        }
      }
      var kept = choice
      kept.id = winner
      kept.version = s.baseline[winner]?.version ?? 0
      if s.baseline[winner]?.equivalent(kept) == true {
        s.records[winner] = kept
      } else {
        save(kept, &s)
      }
    }
  }
  public func deletionAttempt(keepLocal: Bool?) throws {
    try change { $0.deletionChoice = keepLocal }
  }
  public func postpone(until: Date) throws { try change { $0.retryAfter = until } }
  public func disconnectAfterDeletion(keepLocal: Bool) throws {
    try change { s in
      var local = JournalState()
      if keepLocal {
        local.settings = s.settings
        local.customized = s.customized
        local.importConflicts = s.importConflicts
        local.records = s.records.filter { !$0.value.deleted }.mapValues {
          var r = $0
          r.version = 0
          return r
        }
      }
      s = local
    }
  }
}
