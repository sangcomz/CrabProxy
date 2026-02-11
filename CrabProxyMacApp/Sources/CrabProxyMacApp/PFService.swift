import Foundation

enum PFServiceError: LocalizedError, Sendable {
  case commandFailed(command: String, message: String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let message):
      if message.isEmpty {
        return "PF command failed: \(command)"
      }
      return "PF command failed (\(command)): \(message)"
    }
  }
}

protocol PFServicing: Sendable {
  func enable(proxyPort: Int) throws
  func disable() throws
}

struct LivePFService: PFServicing {
  func enable(proxyPort: Int) throws {
    try PFService.enable(proxyPort: proxyPort)
  }

  func disable() throws {
    try PFService.disable()
  }
}

enum PFService {
  private static let excludePortStart = 50000
  private static let excludePortEnd = 50099

  /// Enable pf transparent proxy redirect rules.
  ///
  /// Creates a combined pf config that includes the system defaults and adds
  /// CrabProxy redirect rules. Uses AppleScript `do shell script ... with
  /// administrator privileges` to get root access for pfctl.
  static func enable(proxyPort: Int) throws {
    // Build a pf config that loads system defaults then adds our rules.
    // The rdr rule redirects outbound 80/443 to our transparent listener.
    // The pass-out-quick rule lets the proxy's own upstream connections
    // (bound to source ports 50000-50099) bypass the redirect.
    // The route-to rule forces outbound 80/443 through lo0 where rdr catches it.
    let pfConf = """
      scrub-anchor "com.apple/*"
      nat-anchor "com.apple/*"
      rdr-anchor "com.apple/*"
      rdr on lo0 proto tcp from any to any port {80, 443} -> 127.0.0.1 port \(proxyPort)
      anchor "com.apple/*"
      load anchor "com.apple" from "/etc/pf.anchors/com.apple"
      pass out quick proto tcp from any port \(excludePortStart):\(excludePortEnd) to any no state
      pass out route-to lo0 inet proto tcp from any to any port {80, 443} keep state
      """

    let confPath = NSTemporaryDirectory() + "crab-proxy-pf.conf"
    try pfConf.write(toFile: confPath, atomically: true, encoding: .utf8)

    let script = "/sbin/pfctl -f '\(confPath)' -e 2>/dev/null; true"
    try runWithAdminPrivileges(script)
  }

  /// Disable pf transparent proxy by restoring system default rules.
  static func disable() throws {
    let script = "/sbin/pfctl -f /etc/pf.conf 2>/dev/null; true"
    try runWithAdminPrivileges(script)
  }

  /// Run a shell command with admin privileges using osascript.
  /// This triggers the standard macOS password dialog.
  private static func runWithAdminPrivileges(_ script: String) throws {
    let escaped = script
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    let osascript = "do shell script \"\(escaped)\" with administrator privileges"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", osascript]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
      throw PFServiceError.commandFailed(
        command: "pfctl",
        message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
