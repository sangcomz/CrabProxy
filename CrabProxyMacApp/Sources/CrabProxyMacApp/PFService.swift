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
  func enable(proxyPort: Int, certInstallPath: String?) async throws
  func disable() async throws
}

struct LivePFService: PFServicing {
  private let helperClient = HelperClient()

  func enable(proxyPort: Int, certInstallPath: String? = nil) async throws {
    let pfConf = PFService.buildPFConf(proxyPort: proxyPort)
    do {
      try await helperClient.enablePF(pfConf: pfConf, certPath: certInstallPath)
    } catch {
      guard shouldFallbackToLegacy(error) else { throw error }
      try await Task.detached(priority: .userInitiated) {
        try PFService.enableLegacy(proxyPort: proxyPort, certInstallPath: certInstallPath)
      }.value
    }
  }

  func disable() async throws {
    do {
      try await helperClient.disablePF()
    } catch {
      guard shouldFallbackToLegacy(error) else { throw error }
      try await Task.detached(priority: .userInitiated) {
        try PFService.disableLegacy()
      }.value
    }
  }

  private func shouldFallbackToLegacy(_ error: Error) -> Bool {
    if case HelperClientError.connectionFailed = error {
      return true
    }
    if case HelperClientError.remoteError(let message) = error {
      let lowered = message.lowercased()
      return lowered.contains("xpc")
        || lowered.contains("connection")
        || lowered.contains("listener")
        || lowered.contains("invalidated")
        || lowered.contains("service")
    }
    return false
  }
}

/// Fallback service that uses osascript (admin password prompt each time).
struct LegacyPFService: PFServicing {
  func enable(proxyPort: Int, certInstallPath: String? = nil) async throws {
    try PFService.enableLegacy(proxyPort: proxyPort, certInstallPath: certInstallPath)
  }

  func disable() async throws {
    try PFService.disableLegacy()
  }
}

enum PFService {
  static let excludePortStart = 50000
  static let excludePortEnd = 50099

  static func buildPFConf(proxyPort: Int) -> String {
    """
    scrub-anchor "com.apple/*"
    nat-anchor "com.apple/*"
    rdr-anchor "com.apple/*"
    rdr on lo0 proto tcp from any to any port {80, 443} -> 127.0.0.1 port \(proxyPort)
    anchor "com.apple/*"
    load anchor "com.apple" from "/etc/pf.anchors/com.apple"
    pass out quick proto tcp from any port \(excludePortStart):\(excludePortEnd) to any no state
    pass out route-to lo0 inet proto tcp from any to any port {80, 443} keep state
    """
  }

  // MARK: - Legacy (osascript-based) implementation

  static func enableLegacy(proxyPort: Int, certInstallPath: String? = nil) throws {
    let pfConf = buildPFConf(proxyPort: proxyPort)
    let confPath = NSTemporaryDirectory() + "crab-proxy-pf.conf"
    try pfConf.write(toFile: confPath, atomically: true, encoding: .utf8)

    var parts: [String] = []

    if let certPath = certInstallPath {
      let escapedCert = certPath.replacingOccurrences(of: "'", with: "'\\''")
      parts.append(
        "/usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '\(escapedCert)'"
      )
    }

    parts.append("/sbin/pfctl -f '\(confPath)' -e 2>/dev/null; true")

    let script = parts.joined(separator: " && ")
    try runWithAdminPrivileges(script)
  }

  static func disableLegacy() throws {
    let script = "/sbin/pfctl -f /etc/pf.conf 2>/dev/null; true"
    try runWithAdminPrivileges(script)
  }

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
        command: "admin",
        message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
