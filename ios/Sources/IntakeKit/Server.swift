import Foundation

public struct Profile: Codable {
  public let id: String, username: String, settings: Settings
}
private struct Credentials: Encodable { let username: String, password: String, timezone: String }
private struct Registration: Decodable { let allowed: Bool }
private struct Capabilities: Decodable { let account_deletion: Bool }
public enum ServerError: LocalizedError {
  case response(Int, Int?)
  case invalidCredentials, cursorReset, wrongAccount, routeUnavailable, invalid
  public var errorDescription: String? {
    switch self {
    case .invalidCredentials: return "Username or password wasn’t recognized."
    case .response(401, _): return "Sign in again to sync this account."
    case .response(429, let delay): return "Too many requests. Retry in \(delay ?? 60) seconds."
    case .response(let n, _): return "The server could not complete the request (\(n))."
    case .wrongAccount: return "Sign in to the same server account."
    case .routeUnavailable: return "The saved address no longer resolves to this account’s server."
    case .invalid: return "The server returned an invalid journal response."
    case .cursorReset: return "The server history was restored."
    }
  }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
public final class Server {
  public let origin: URL
  public let savedOrigin: URL
  private let session: URLSession
  public convenience init(_ address: String) throws {
    self.init(origin: try ServerRoute.parse(address))
  }
  internal init(origin: URL, saved: URL? = nil, configuration: URLSessionConfiguration = .ephemeral)
  {
    self.origin = origin
    savedOrigin = saved ?? origin
    let config = configuration
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.timeoutIntervalForRequest = 25
    session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  /// Guest probes never carry the password, cookie, account ID, or an operation body.
  public enum Purpose { case login, signup, availability }
  public static func discover(_ address: String, purpose: Purpose = .login) async throws -> Server {
    try await discover(address, purpose: purpose, configuration: .ephemeral)
  }
  internal static func discover(
    _ address: String, purpose: Purpose = .login, configuration: URLSessionConfiguration
  )
    async throws -> Server
  {
    let client = Server(origin: try ServerRoute.parse(address), configuration: configuration)
    func probe(_ url: URL, method: String) async throws -> (Int, String?) {
      var req = URLRequest(url: url)
      req.httpMethod = method
      req.setValue("1", forHTTPHeaderField: "X-Intake-Discover")
      let (bytes, response) = try await client.session.bytes(for: req)
      defer { bytes.task.cancel() }  // Only the headers matter during discovery.
      guard let http = response as? HTTPURLResponse else { throw ServerError.invalid }
      return (http.statusCode, http.value(forHTTPHeaderField: "Location"))
    }
    let root = try await ServerRoute.resolve(client.origin) { try await probe($0, method: "GET") }
    var route = try await ServerRoute.resolve(
      root.endpoint.appendingPathComponent("api/registration"), previous: root,
      apiPath: "api/registration"
    ) { try await probe($0, method: "GET") }
    if purpose != .availability {
      // Some reverse proxies redirect only the authentication path. Probe
      // using its real method with no password, session, or signup body.
      let path = purpose == .signup ? "api/signup" : "api/session"
      route = try await ServerRoute.resolve(
        route.endpoint.appendingPathComponent(path), previous: route, apiPath: path
      ) {
        try await probe($0, method: "POST")
      }
    }
    let server = Server(origin: route.endpoint, saved: route.saved, configuration: configuration)
    _ = try JSONDecoder().decode(Registration.self, from: await server.call("registration").0)
    return server
  }
  public static func resume(_ binding: Binding) async throws -> Server {
    try await resume(binding, configuration: .ephemeral)
  }
  internal static func resume(_ binding: Binding, configuration: URLSessionConfiguration)
    async throws -> Server
  {
    guard let alias = binding.discoveryOrigin else {
      return try Server(origin: ServerRoute.parse(binding.origin), configuration: configuration)
    }
    let server: Server
    do {
      server = try await discover(alias, configuration: configuration)
    } catch ServerError.response(401, _) {
      throw ServerError.routeUnavailable
    }
    guard server.origin.absoluteString == binding.origin else { throw ServerError.routeUnavailable }
    return server
  }
  private func call(
    _ path: String, method: String = "GET", body: Data? = nil, token: String? = nil,
    account: String? = nil, basic: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    var req = URLRequest(url: origin.appendingPathComponent("api").appendingPathComponent(path))
    req.httpMethod = method
    req.httpBody = body
    req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { req.setValue("intake_session=" + token, forHTTPHeaderField: "Cookie") }
    req.setValue(account, forHTTPHeaderField: "X-Intake-Account")
    req.setValue(basic, forHTTPHeaderField: "Authorization")
    var seen = Set<URL>()
    var data = Data()
    var response: URLResponse
    repeat {
      guard let url = req.url, seen.count < 10, seen.insert(url).inserted else {
        throw Problem.message("The API returned a redirect loop.")
      }
      (data, response) = try await session.data(for: req)
      guard let http = response as? HTTPURLResponse, ServerRoute.redirects.contains(http.statusCode)
      else { break }
      guard let location = http.value(forHTTPHeaderField: "Location"),
        let target = URL(string: location, relativeTo: url)?.absoluteURL,
        try ServerRoute.origin(target) == origin, target.path.hasPrefix("/api/"),
        method == "GET" || [307, 308].contains(http.statusCode)
      else { throw Problem.message("The API moved. Reconnect using its server address.") }
      req.url = target
    } while true
    guard let http = response as? HTTPURLResponse else { throw ServerError.invalid }
    if http.statusCode == 409, path == "sync",
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (json["detail"] as? [String: Any])?["code"] as? String == "cursor_reset"
    {
      throw ServerError.cursorReset
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ServerError.response(
        http.statusCode, http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
    }
    return (data, http)
  }
  public func canDelete() async throws -> Bool {
    do {
      return try JSONDecoder().decode(Capabilities.self, from: await call("capabilities").0)
        .account_deletion
    } catch ServerError.response(404, _) { return false }
  }
  public func canRegister() async throws -> Bool {
    guard try await canDelete() else { return false }
    return try JSONDecoder().decode(Registration.self, from: await call("registration").0).allowed
  }
  public func authenticate(username: String, password: String, signup: Bool, timezone: String)
    async throws -> (Profile, String)
  {
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let answer: (Data, HTTPURLResponse)
    if signup {
      guard try await canRegister() else {
        throw Problem.message("This server does not offer native signup.")
      }
      let payload = try JSONEncoder().encode(
        Credentials(username: username, password: password, timezone: timezone))
      answer = try await call("signup", method: "POST", body: payload)
    } else {
      let basic = Data("\(username):\(password)".utf8).base64EncodedString()
      do {
        answer = try await call("session", method: "POST", basic: "Basic " + basic)
      } catch ServerError.response(401, _) {
        throw ServerError.invalidCredentials
      }
    }
    guard let header = answer.1.value(forHTTPHeaderField: "Set-Cookie"),
      let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: origin)
        .first(where: { $0.name == "intake_session" && $0.path == "/api" }),
      !cookie.value.isEmpty
    else { throw Problem.message("Server did not establish an Intake session.") }
    if cookie.isSecure, origin.scheme != "https" {
      throw Problem.message("This server requires HTTPS for its session. Use its HTTPS address.")
    }
    let profile = try JSONDecoder().decode(Profile.self, from: answer.0)
    _ = try await me(cookie.value, account: profile.id)
    return (profile, cookie.value)
  }
  public func me(_ token: String, account: String) async throws -> Profile {
    let p = try JSONDecoder().decode(
      Profile.self, from: await call("me", token: token, account: account).0)
    guard p.id == account else { throw ServerError.wrongAccount }
    return p
  }
  public func pull(_ body: Data, token: String, account: String) async throws -> Page {
    try JSONDecoder().decode(
      Page.self,
      from: await call("sync", method: "POST", body: body, token: token, account: account).0)
  }
  public func snapshot(token: String, account: String) async throws -> ([Record], Int) {
    var rows: [String: Record] = [:]
    var cursor = 0
    while true {
      try Task.checkCancellation()
      let page = try await pull(
        Data("{\"operations\":[],\"cursor\":\(cursor)}".utf8), token: token, account: account)
      guard !page.has_more || page.cursor > cursor else { throw ServerError.invalid }
      for row in page.changes where row.version >= (rows[row.id]?.version ?? -1) {
        rows[row.id] = row
      }
      cursor = page.cursor
      if !page.has_more { break }
    }
    return (Array(rows.values), cursor)
  }
  public func deleteItem(_ id: String, token: String, account: String) async throws {
    _ = try await call("items/" + id, method: "DELETE", token: token, account: account)
  }
  public func deleteAccount(token: String, account: String) async throws {
    _ = try await call("account", method: "DELETE", token: token, account: account)
  }
  public func logout(token: String, account: String) async throws {
    _ = try await call("logout", method: "POST", token: token, account: account)
  }
  public func settings(_ settings: Settings, token: String, account: String) async throws {
    _ = try await call(
      "settings", method: "PUT", body: JSONEncoder().encode(settings), token: token,
      account: account)
  }
  public func spreadsheet(_ snapshot: Data, token: String, account: String) async throws -> Data {
    try await call("export", method: "POST", body: snapshot, token: token, account: account).0
  }
}
