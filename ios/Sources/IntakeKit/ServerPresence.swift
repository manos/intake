import Foundation

/// A working network path alone doesn't mean the user's server is reachable.
public struct ServerPresence {
  public enum Badge { case checking, connected, offline, syncFailed }
  public private(set) var generation = UUID()
  private var offline = false
  private var response: (server: String, reachable: Bool)?
  private var failedServer: String?
  public init() {}

  public mutating func networkChanged(offline: Bool) {
    self.offline = offline
    invalidate()
  }
  public mutating func invalidate() {
    response = nil
    generation = UUID()
  }
  public mutating func report(server: String, generation: UUID, reachable: Bool) {
    guard self.generation == generation, !offline else { return }
    response = (server, reachable)
  }
  public mutating func finishedSync(server: String, succeeded: Bool) {
    failedServer = succeeded ? nil : server
  }
  /// Today displays reachability only. An unresolved edit doesn't mean the
  /// phone is disconnected, and signing out hides the cloud altogether.
  public func connected(server: String?, signedIn: Bool) -> Bool? {
    guard signedIn, let server else { return nil }
    return !offline && response?.server == server && response?.reachable == true
  }
  public func badge(server: String?, signedIn: Bool) -> Badge? {
    guard signedIn, let server else { return nil }
    if failedServer == server { return .syncFailed }
    if offline { return .offline }
    guard let response, response.server == server else { return .checking }
    return response.reachable ? .connected : .offline
  }
}
