import Foundation
import XCTest

@testable import IntakeKit

/// CI starts an isolated FastAPI process on loopback; the shipping transport is HTTPS-only.
final class BackendInteropTests: XCTestCase {
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
    let restored = try Journal(file: file)
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
