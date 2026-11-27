import Foundation
import XCTest

@testable import IntakeKit

/// CI starts an isolated HTTP FastAPI process on loopback.
final class BackendInteropTests: XCTestCase {
  func testDraggedItemOrderSyncsToAnotherPhone() async throws {
    guard let root = ProcessInfo.processInfo.environment["INTAKE_INTEROP_ORIGIN"],
      URL(string: root)?.host == "127.0.0.1"
    else { throw XCTSkip("Requires the disposable loopback backend.") }
    let server = try await Server.discover(root, purpose: .signup)
    let (user, token) = try await server.authenticate(
      username: UUID().uuidString, password: UUID().uuidString, signup: true, timezone: "UTC")
    let binding = Binding(
      origin: server.origin.absoluteString, account: user.id, username: user.username)
    let source = try Journal()
    try source.link(binding, remote: [], cursor: 0, settings: user.settings)
    let data = try Data(
      contentsOf: XCTUnwrap(
        Bundle.module.url(forResource: "web", withExtension: "json", subdirectory: "Fixtures")))
    let a = try XCTUnwrap(Transfer.decode(data, csv: false).first(where: { $0.entity == .item }))
    var z = a
    z.id = UUID().uuidString.lowercased()
    z.data["name"] = .string("Z")
    z.data["order"] = .number(1)
    try source.put(a)
    try source.put(z)
    func flush() async throws {
      let page = try await server.pull(
        source.requestBody(source.batch()), token: token, account: user.id)
      XCTAssertEqual(page.results.map(\.status), ["applied", "applied"])
      try source.accept(page)
    }
    try await flush()
    try source.reorderItems([z.id, a.id], replacing: [a.id, z.id])
    try await flush()
    let (remote, cursor) = try await server.snapshot(token: token, account: user.id)
    let second = try Journal()
    try second.link(binding, remote: remote, cursor: cursor, settings: user.settings)
    XCTAssertEqual(try JournalDisplay(second.read()).activeItems.map(\.id), [z.id, a.id])
    try await server.deleteAccount(token: token, account: user.id)
  }
  func testFormattedDayFromOfflinePhoneAppearsOnSecondClient() async throws {
    guard let root = ProcessInfo.processInfo.environment["INTAKE_INTEROP_ORIGIN"],
      URL(string: root)?.host == "127.0.0.1"
    else { throw XCTSkip("Requires the disposable loopback backend.") }
    let local = try Journal()
    let day = "2026-11-26"
    let note = Record(
      .day, id: JournalTime.dayID(day),
      data: [
        "date": .string(day), "note": .string("🌿 Morning\nSecond line."), "zero": .bool(false),
        "styles": .array([DayStyle(range: NSRange(location: 3, length: 7), flags: 3).wire]),
      ])
    try local.put(note)
    let server = try await Server.discover(root)
    let (user, token) = try await server.authenticate(
      username: UUID().uuidString, password: UUID().uuidString, signup: true, timezone: "UTC")
    let binding = Binding(
      origin: server.origin.absoluteString, account: user.id, username: user.username)
    try local.link(binding, remote: [], cursor: 0, settings: user.settings)
    let result = try await server.pull(
      local.requestBody(local.batch()), token: token, account: user.id)
    XCTAssertEqual(result.results.first?.status, "applied")
    try local.accept(result)
    let (records, cursor) = try await server.snapshot(token: token, account: user.id)
    let second = try Journal()
    try second.link(binding, remote: records, cursor: cursor, settings: user.settings)
    let restored = try XCTUnwrap(JournalDisplay(second.read()).notesByDay[day]?.first)
    XCTAssertEqual(restored.id, note.id)
    XCTAssertEqual(restored.data, note.data)
    XCTAssertEqual(
      try DayStyle.spans(in: restored), [DayStyle(range: NSRange(location: 3, length: 7), flags: 3)]
    )
    try await server.deleteAccount(token: token, account: user.id)
  }
  func testNativeLoginAndRelaunchUseDifferentErrorsForCredentialsAndSession() async throws {
    guard let root = ProcessInfo.processInfo.environment["INTAKE_INTEROP_ORIGIN"],
      let origin = URL(string: root), origin.host == "127.0.0.1"
    else { throw XCTSkip("Requires the disposable loopback backend.") }
    let username = UUID().uuidString
    // Spaces are permitted in a password; only surrounding username whitespace is ignored.
    let password = " " + UUID().uuidString + " "
    let client = try await Server.discover(origin.absoluteString)
    let (account, _) = try await client.authenticate(
      username: username, password: password, signup: true, timezone: "UTC")
    do {
      _ = try await client.authenticate(
        username: username, password: UUID().uuidString, signup: false, timezone: "UTC")
      XCTFail("A rejected login must not establish a session")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Username or password wasn’t recognized.")
    }
    let (signedIn, token) = try await client.authenticate(
      username: " \(username)\n", password: password, signup: false, timezone: "UTC")
    XCTAssertEqual(signedIn.id, account.id)
    let reopened = Server(origin: origin)
    let restored = try await reopened.me(token, account: account.id)
    XCTAssertEqual(restored.id, account.id)
    _ = try await reopened.snapshot(token: token, account: account.id)
    try await reopened.logout(token: token, account: account.id)
    do {
      _ = try await reopened.me(token, account: account.id)
      XCTFail("A revoked session must not sync")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Sign in again to sync this account.")
    }
  }
  func testLostAcknowledgementAndPurgeOnExistingServer() async throws {
    guard let root = ProcessInfo.processInfo.environment["INTAKE_INTEROP_ORIGIN"],
      let origin = URL(string: root),
      origin.host == "127.0.0.1"
    else { throw XCTSkip("Requires the disposable loopback backend.") }
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    let network = URLSession(configuration: config)
    defer { network.invalidateAndCancel() }
    let password = UUID().uuidString
    let username = UUID().uuidString
    func call(
      _ path: String, _ method: String, _ data: Data? = nil, _ cookie: String? = nil,
      _ id: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
      var req = URLRequest(url: origin.appendingPathComponent("api/" + path))
      req.httpMethod = method
      req.httpBody = data
      req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.setValue(cookie, forHTTPHeaderField: "Cookie")
      req.setValue(id, forHTTPHeaderField: "X-Intake-Account")
      let (data, response) = try await network.data(for: req)
      return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }
    let (profileData, registered) = try await call(
      "signup", "POST",
      JSONEncoder().encode(["username": username, "password": password, "timezone": "UTC"]))
    XCTAssertEqual(registered.statusCode, 201)
    let profile = try JSONDecoder().decode(Profile.self, from: profileData)
    let cookie = try XCTUnwrap(
      registered.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
    let rows = try Transfer.decode(
      Data(
        contentsOf: XCTUnwrap(
          Bundle.module.url(forResource: "web", withExtension: "json", subdirectory: "Fixtures"))),
      csv: false)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let j = try Journal(file: file)
    try j.applyImport(rows)
    let binding = Binding(origin: root, account: profile.id, username: username)
    try j.link(binding, remote: [], cursor: 0, settings: profile.settings)
    func sync(_ body: Data) async throws -> Page {
      let (data, http) = try await call("sync", "POST", body, cookie, profile.id)
      XCTAssertEqual(http.statusCode, 200)
      return try JSONDecoder().decode(Page.self, from: data)
    }
    let first = try j.requestBody(j.batch())
    _ = try await sync(first)  // server commits; the first device never applies the response
    try j.setConnectionPaused(true, for: binding)
    let restored = try Journal(file: file)
    XCTAssertTrue(try restored.batch().isEmpty)
    try restored.setConnectionPaused(false, for: binding)
    let replay = try restored.requestBody(restored.batch())
    XCTAssertEqual(first, replay)
    try restored.accept(await sync(replay))
    try restored.accept(await sync(restored.requestBody(restored.batch())))
    let pull = Data(#"{"operations":[],"cursor":0}"#.utf8)
    let account = try await sync(pull)
    XCTAssertEqual(account.changes.count, 2)
    let fresh = try Journal()
    try fresh.link(
      binding, remote: account.changes, cursor: account.cursor, settings: profile.settings)
    XCTAssertEqual(try fresh.read().visible(.entry).first?.text("quantity"), "0.125")
    XCTAssertTrue(try fresh.batch().isEmpty)
    let item = try XCTUnwrap(fresh.read().visible(.item).first)
    for preset in try XCTUnwrap(item.data["presets"]?.values) {
      try fresh.put(item.entry(settings: profile.settings, amount: preset.text))
    }
    let logged = try await sync(fresh.requestBody(fresh.batch()))
    XCTAssertEqual(logged.results.map(\.status), ["applied", "applied"])
    XCTAssertEqual(logged.results.map { $0.record?.text("quantity") }, ["1", "0.125"])
    try fresh.accept(logged)
    // A stale device's offline entry must disappear when the item is purged.
    var child = rows[1]
    child.id = UUID().uuidString.lowercased()
    try fresh.put(child)
    try restored.purge(rows[0].id)
    let (_, deleted) = try await call("items/" + rows[0].id, "DELETE", nil, cookie, profile.id)
    XCTAssertEqual(deleted.statusCode, 200)
    try fresh.accept(await sync(fresh.requestBody(fresh.batch())))
    XCTAssertTrue(try fresh.read().visible(.entry).isEmpty)
    XCTAssertTrue(try fresh.batch().isEmpty)
    let (_, done) = try await call("account", "DELETE", nil, cookie, profile.id)
    XCTAssertEqual(done.statusCode, 204)
    let (_, signedOut) = try await call("me", "GET", nil, cookie, profile.id)
    XCTAssertEqual(signedOut.statusCode, 401)
  }
}
