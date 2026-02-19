import Foundation
import Security

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
  private static let expectedHelperIdentifier = "com.sangcomz.CrabProxyHelper"

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

  private struct CodeSigningIdentity {
    let identifier: String
    let teamIdentifier: String
  }

  private static func verifyHelperBinary(at path: String) -> Bool {
    guard
      let appIdentity = currentProcessIdentity(),
      let helperIdentity = identityForBinary(at: path)
    else {
      return false
    }

    return helperIdentity.identifier == expectedHelperIdentifier
      && helperIdentity.teamIdentifier == appIdentity.teamIdentifier
  }

  private static func currentProcessIdentity() -> CodeSigningIdentity? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let selfCode = code else {
      return nil
    }

    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(selfCode, SecCSFlags(), &staticCode) == errSecSuccess,
      let selfStaticCode = staticCode
    else {
      return nil
    }

    return signingIdentity(from: selfStaticCode)
  }

  private static func identityForBinary(at path: String) -> CodeSigningIdentity? {
    let url = URL(fileURLWithPath: path)
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
      let binaryStaticCode = staticCode
    else {
      return nil
    }

    return signingIdentity(from: binaryStaticCode)
  }

  private static func signingIdentity(from staticCode: SecStaticCode) -> CodeSigningIdentity? {
    guard SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess else {
      return nil
    }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
      let signingInfo = info as? [String: Any],
      let identifier = signingInfo[kSecCodeInfoIdentifier as String] as? String,
      let teamIdentifier = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
    else {
      return nil
    }

    return CodeSigningIdentity(identifier: identifier, teamIdentifier: teamIdentifier)
  }

  private static func findHelperBinary() throws -> String {
    // 1. Check inside the app bundle Resources
    for candidate in helperBinaryCandidates {
      if let bundlePath = Bundle.main.path(forResource: candidate, ofType: nil),
         verifyHelperBinary(at: bundlePath) {
        return bundlePath
      }
    }

    // 2. Check next to the main executable (SPM build product)
    if let execURL = Bundle.main.executableURL {
      let parentDir = execURL.deletingLastPathComponent()
      for candidate in helperBinaryCandidates {
        let siblingPath = parentDir.appendingPathComponent(candidate).path
        if FileManager.default.fileExists(atPath: siblingPath),
           verifyHelperBinary(at: siblingPath) {
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
          if FileManager.default.fileExists(atPath: candidatePath),
             verifyHelperBinary(at: candidatePath) {
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
