import Foundation

enum CACertServiceError: LocalizedError, Sendable {
  case commandFailed(message: String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let message):
      return message.isEmpty ? "Certificate command failed" : message
    }
  }
}

protocol CACertServicing: Sendable {
  func installToSystemKeychain(certPath: String) async throws
  func removeFromSystemKeychain(commonName: String) async throws
  func isInstalledInSystemKeychain(commonName: String) async -> Bool
}

struct LiveCACertService: CACertServicing {
  private let helperClient = HelperClient()

  func installToSystemKeychain(certPath: String) async throws {
    do {
      try await helperClient.installCert(certPath: certPath)
    } catch {
      guard shouldFallbackToLegacy(error) else { throw error }
      try await Task.detached(priority: .userInitiated) {
        try LegacyCACertService.install(certPath: certPath)
      }.value
    }
  }

  func removeFromSystemKeychain(commonName: String) async throws {
    do {
      try await helperClient.removeCert(commonName: commonName)
    } catch {
      guard shouldFallbackToLegacy(error) else { throw error }
      try await Task.detached(priority: .userInitiated) {
        try LegacyCACertService.remove(commonName: commonName)
      }.value
    }
  }

  func isInstalledInSystemKeychain(commonName: String) async -> Bool {
    if await helperClient.checkCert(commonName: commonName) {
      return true
    }
    if await helperClient.isAvailable() {
      return false
    }
    return LegacyCACertService.isInstalled(commonName: commonName)
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
struct LegacyCACertService: CACertServicing {
  func installToSystemKeychain(certPath: String) async throws {
    try Self.install(certPath: certPath)
  }

  func removeFromSystemKeychain(commonName: String) async throws {
    try Self.remove(commonName: commonName)
  }

  func isInstalledInSystemKeychain(commonName: String) async -> Bool {
    Self.isInstalled(commonName: commonName)
  }

  static func install(certPath: String) throws {
    let escapedPath = certPath.replacingOccurrences(of: "'", with: "'\\''")
    let script =
      "/usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '\(escapedPath)'"
    try runWithAdminPrivileges(script)
  }

  static func remove(commonName: String) throws {
    let escapedName = commonName.replacingOccurrences(of: "'", with: "'\\''")
    let script =
      "/usr/bin/security delete-certificate -c '\(escapedName)' /Library/Keychains/System.keychain"
    try runWithAdminPrivileges(script)
  }

  static func isInstalled(commonName: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
      "find-certificate", "-c", commonName, "/Library/Keychains/System.keychain",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  fileprivate static func runWithAdminPrivileges(_ script: String) throws {
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
      throw CACertServiceError.commandFailed(
        message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
