import Foundation

enum HelperInstallerError: LocalizedError, Sendable {
  case binaryNotFound
  case installFailed(String)
  case uninstallFailed(String)

  var errorDescription: String? {
    switch self {
    case .binaryNotFound:
      return "Helper binary not found in app bundle or build products"
    case .installFailed(let message):
      return "Helper install failed: \(message)"
    case .uninstallFailed(let message):
      return "Helper uninstall failed: \(message)"
    }
  }
}

enum HelperInstaller {
  static let helperLabel = "com.sangcomz.CrabProxyHelper"
  static let helperToolPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
  static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
  private static let helperBinaryCandidates = [helperLabel, "CrabProxyHelper"]

  static func install() throws {
    let binaryPath = try findHelperBinary()
    let plistContent = makeLaunchdPlist()

    let plistTmpPath = NSTemporaryDirectory() + "\(helperLabel).plist"
    try plistContent.write(toFile: plistTmpPath, atomically: true, encoding: .utf8)

    let escapedBinary = binaryPath.replacingOccurrences(of: "'", with: "'\\''")
    let escapedPlistTmp = plistTmpPath.replacingOccurrences(of: "'", with: "'\\''")

    let script = [
      "mkdir -p /Library/PrivilegedHelperTools",
      "cp '\(escapedBinary)' '\(helperToolPath)'",
      "chmod 544 '\(helperToolPath)'",
      "chown root:wheel '\(helperToolPath)'",
      "cp '\(escapedPlistTmp)' '\(launchDaemonPlistPath)'",
      "chmod 644 '\(launchDaemonPlistPath)'",
      "chown root:wheel '\(launchDaemonPlistPath)'",
      "launchctl bootout system/\(helperLabel) 2>/dev/null; true",
      "launchctl bootstrap system '\(launchDaemonPlistPath)'",
    ].joined(separator: " && ")

    try runWithAdminPrivileges(script, action: .install)
  }

  static func uninstall() throws {
    let script = [
      "launchctl bootout system/\(helperLabel) 2>/dev/null; true",
      "rm -f '\(helperToolPath)'",
      "rm -f '\(launchDaemonPlistPath)'",
    ].joined(separator: " && ")

    try runWithAdminPrivileges(script, action: .uninstall)
  }

  static func isInstalled() -> Bool {
    FileManager.default.fileExists(atPath: helperToolPath)
      && FileManager.default.fileExists(atPath: launchDaemonPlistPath)
  }

  // MARK: - Private

  private static func findHelperBinary() throws -> String {
    // 1. Check inside the app bundle Resources
    for candidate in helperBinaryCandidates {
      if let bundlePath = Bundle.main.path(forResource: candidate, ofType: nil) {
        return bundlePath
      }
    }

    // 2. Check next to the main executable (SPM build product)
    if let execURL = Bundle.main.executableURL {
      let parentDir = execURL.deletingLastPathComponent()
      for candidate in helperBinaryCandidates {
        let siblingPath = parentDir.appendingPathComponent(candidate).path
        if FileManager.default.fileExists(atPath: siblingPath) {
          return siblingPath
        }
      }
    }

    // 3. Check common SPM build directories relative to executable
    if let execURL = Bundle.main.executableURL {
      // Traverse up to find .build directory
      var dir = execURL.deletingLastPathComponent()
      for _ in 0..<7 {
        for candidate in helperBinaryCandidates {
          let candidatePath = dir.appendingPathComponent(candidate).path
          if FileManager.default.fileExists(atPath: candidatePath) {
            return candidatePath
          }
        }
        dir = dir.deletingLastPathComponent()
      }
    }

    throw HelperInstallerError.binaryNotFound
  }

  private static func makeLaunchdPlist() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(helperLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(helperToolPath)</string>
        </array>
        <key>MachServices</key>
        <dict>
            <key>\(helperLabel)</key>
            <true/>
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
    </plist>
    """
  }

  private enum InstallAction {
    case install
    case uninstall
  }

  private static func runWithAdminPrivileges(_ script: String, action: InstallAction) throws {
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
      let trimmed = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      let message = trimmed.isEmpty ? "Exit code \(process.terminationStatus)" : trimmed
      switch action {
      case .install:
        throw HelperInstallerError.installFailed(message)
      case .uninstall:
        throw HelperInstallerError.uninstallFailed(message)
      }
    }
  }
}
