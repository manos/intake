import Foundation
import Network

/// Only the uninterrupted prefix of permanent redirects is safe to remember.
struct ServerRoute {
  let saved: URL
  let endpoint: URL
  let temporary: Bool

  static func origin(_ url: URL) throws -> URL {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = c.host, !host.isEmpty,
      host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      c.user == nil, c.password == nil, c.port.map({ (1...65535).contains($0) }) ?? true
    else { throw Problem.message("Enter a valid HTTP or HTTPS server address.") }
    c.scheme = scheme
    c.host = host.lowercased()
    if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
    c.path = ""
    c.query = nil
    c.fragment = nil
    guard let result = c.url else { throw ServerError.invalid }
    return result
  }

  static func parse(_ address: String) throws -> URL {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = IPv6Address(text) == nil ? text : "[\(text)]"
    let input = text.contains("://") ? text : "http://" + host
    guard let c = URLComponents(string: input), c.path.isEmpty || c.path == "/",
      c.query == nil, c.fragment == nil, let url = c.url
    else {
      throw Problem.message("Enter a server hostname or HTTP(S) address without a path.")
    }
    return try origin(url)
  }

  static let redirects = [301, 302, 303, 307, 308]
  static func resolve(
    _ start: URL, previous: ServerRoute? = nil, apiPath: String? = nil,
    probe: (URL) async throws -> (Int, String?)
  ) async throws -> ServerRoute {
    var current = start
    var saved = try previous?.saved ?? origin(start)
    var temporary = previous?.temporary ?? false
    var seen = Set<URL>()
    for _ in 0...10 {
      guard seen.insert(current).inserted else {
        throw Problem.message("The server redirects in a loop.")
      }
      let (status, location) = try await probe(current)
      guard redirects.contains(status) else {
        return ServerRoute(saved: saved, endpoint: try origin(current), temporary: temporary)
      }
      guard let location, let next = URL(string: location, relativeTo: current)?.absoluteURL else {
        throw Problem.message("The server returned an invalid redirect.")
      }
      let nextOrigin = try origin(next)
      guard !(current.scheme?.lowercased() == "https" && nextOrigin.scheme == "http") else {
        throw Problem.message(
          "An HTTPS server redirected to HTTP. Enter the intended server directly.")
      }
      if status != 301 && status != 308 { temporary = true }
      if !temporary { saved = nextOrigin }
      if let apiPath, nextOrigin != (try origin(current)), next.path.isEmpty || next.path == "/" {
        current = nextOrigin.appendingPathComponent(apiPath)
      } else {
        current = next
      }
    }
    throw Problem.message("The server returned too many redirects.")
  }
}
