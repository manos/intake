import XCTest

@testable import IntakeKit

final class DailyJournalTests: XCTestCase {
  func testLoginUsesFinalOriginAndExistingAccountJournal() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AliasResponses.self]
    let server = try await Server.discover("garden.test:8111", configuration: config)
    let (user, token) = try await server.authenticate(
      username: "sample", password: UUID().uuidString, signup: false, timezone: "UTC")
    let binding = Binding(
      origin: server.origin.absoluteString, account: user.id, username: user.username)
    XCTAssertEqual(server.savedOrigin.absoluteString, "https://final.test")
    let journal = try Journal()
    let (records, cursor) = try await server.snapshot(token: token, account: user.id)
    try journal.link(binding, remote: records, cursor: cursor, settings: user.settings)
    XCTAssertEqual(try journal.read().binding?.address, "https://final.test")
    do {
      _ = try await server.spreadsheet(Data("{}".utf8), token: token, account: user.id)
      XCTFail("A protected request must not forward its body or credentials to another origin.")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Reconnect")) }
  }
  func testBareIPv6AndExplicitlyClearedFormatting() throws {
    XCTAssertEqual(try Server("::1").origin.absoluteString, "http://[::1]")
    let plain = Record(
      .day, data: ["date": .string("2026-11-26"), "note": .string("daily"), "zero": .bool(false)])
    var cleared = plain
    cleared.data["styles"] = .array([])
    XCTAssertTrue(plain.equivalent(cleared))
  }
  func testArbitraryAddressesAndPorts() throws {
    for (input, normalized) in [
      ("studio-pc", "http://studio-pc"), (" Some-Box.LAN:8080 ", "http://some-box.lan:8080"),
      ("192.168.1.15:8000", "http://192.168.1.15:8000"),
      ("http://[::1]:8000/", "http://[::1]:8000"),
      ("https://example.com:443/", "https://example.com"),
    ] { XCTAssertEqual(try Server(input).origin.absoluteString, normalized) }
    for bad in ["", "bad host", "ftp://host", "https://name:pw@host", "http://host:65536"] {
      XCTAssertThrowsError(try Server(bad))
    }
  }
  func testPermanentPrefixAndTemporaryHops() async throws {
    let addresses = [
      "http://garden.lan", "https://welcome.example", "https://beta.example",
      "https://current.example",
    ]
    var requests: [String] = []
    let route = try await ServerRoute.resolve(URL(string: addresses[0])!) { url in
      requests.append(url.absoluteString)
      let i = requests.count - 1
      return (i < 3 ? [301, 302, 308][i] : 200, i < 3 ? addresses[i + 1] + "/" : nil)
    }
    XCTAssertEqual(route.saved.absoluteString, addresses[1])
    XCTAssertEqual(route.endpoint.absoluteString, addresses[3])
    XCTAssertEqual(requests.count, 4)
  }
  func testPermanentAliasAndRelativeRedirectLoop() async throws {
    let alias = URL(string: "http://lab.alias")!
    let route = try await ServerRoute.resolve(alias) { url in
      url.host == "lab.alias" ? (308, "https://journal.example/") : (200, nil)
    }
    XCTAssertEqual(route.saved, route.endpoint)
    do {
      _ = try await ServerRoute.resolve(alias) { _ in (302, "/loop") }
      XCTFail("Expected loop rejection")
    } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("redirect")) }
  }
  func testRichDayAndPlainLegacyDayRoundTripWithoutChangingIdentity() throws {
    let j = try Journal()
    let date = "2026-11-26"
    let id = JournalTime.dayID(date)
    let plain = Record(
      .day, id: id,
      data: ["date": .string(date), "note": .string("🌿 Morning"), "zero": .bool(false)])
    try j.put(plain)
    var formatted = plain
    formatted.data["styles"] = .array([.array([.number(3), .number(7), .number(3)])])
    try j.put(formatted)
    let rows = try Transfer.decode(Transfer.export(j.read()), csv: false)
    XCTAssertEqual(rows, [formatted])
    XCTAssertEqual(try DayStyle.spans(in: rows[0]).first?.range, NSRange(location: 3, length: 7))
    formatted.data["styles"] = .array([.array([.number(1), .number(1), .number(1)])])
    XCTAssertThrowsError(try j.put(formatted))
    XCTAssertEqual(try j.read().records[id], rows[0])
  }
  func testAdjacentCivilDaysIgnoreDSTAndLeapBoundaries() {
    XCTAssertEqual(JournalDay.offset("2026-03-08", by: 1), "2026-03-09")
    XCTAssertEqual(JournalDay.offset("2024-03-01", by: -1), "2024-02-29")
    XCTAssertEqual(JournalDay.offset("2026-12-31", by: 1), "2027-01-01")
  }
}

private final class AliasResponses: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let url = request.url!
    var status = 200
    var headers: [String: String] = [:]
    var json = ""
    let account =
      #"{"id":"same-account","username":"sample","settings":{"timezone":"UTC","day_start":0}}"#
    if url.host == "garden.test" {
      XCTAssertEqual(request.httpMethod, "HEAD")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.httpBody)
      status = 301
      headers["Location"] = "https://final.test/"
    } else if url.host == "final.test" {
      switch (request.httpMethod, url.path) {
      case ("HEAD", _): break
      case ("GET", "/api/registration"): json = #"{"allowed":true}"#
      case ("POST", "/api/session"):
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        json = account
        headers["Set-Cookie"] = "intake_session=fixture; Path=/api; HttpOnly; Secure"
      case ("GET", "/api/me"):
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "intake_session=fixture")
        json = account
      case ("POST", "/api/sync"): json = #"{"results":[],"changes":[],"cursor":0,"has_more":false}"#
      case ("POST", "/api/export"):
        status = 307
        headers["Location"] = "https://other.test/api/export"
      default:
        XCTFail("Unexpected request to fixture")
        status = 404
      }
    } else {
      XCTFail("Unexpected destination")
      status = 404
    }
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}
