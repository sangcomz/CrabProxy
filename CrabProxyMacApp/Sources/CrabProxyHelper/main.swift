import Darwin
import Foundation
import Security

final class HelperDelegate: NSObject, NSXPCListenerDelegate, CrabProxyHelperProtocol {
  private let expectedClientIdentifier = "com.sangcomz.CrabProxyMacApp"

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    guard isValidClient(pid: newConnection.processIdentifier) else {
      return false
    }
    newConnection.exportedInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)
    newConnection.exportedObject = self
    newConnection.resume()
    return true
  }

  private struct CodeSigningIdentity {
    let identifier: String
    let teamIdentifier: String
  }

  private func isValidClient(pid: pid_t) -> Bool {
    guard
      let helperIdentity = currentProcessIdentity(),
      let clientIdentity = guestProcessIdentity(pid: pid)
    else {
      return false
    }

    return clientIdentity.identifier == expectedClientIdentifier
      && clientIdentity.teamIdentifier == helperIdentity.teamIdentifier
  }

  private func currentProcessIdentity() -> CodeSigningIdentity? {
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

  private func guestProcessIdentity(pid: pid_t) -> CodeSigningIdentity? {
    guard let executablePath = executablePath(for: pid) else {
      return nil
    }

    var staticCode: SecStaticCode?
    let executableURL = URL(fileURLWithPath: executablePath) as CFURL
    guard
      SecStaticCodeCreateWithPath(executableURL, SecCSFlags(), &staticCode) == errSecSuccess,
      let guestStaticCode = staticCode
    else {
      return nil
    }

    return signingIdentity(from: guestStaticCode)
  }

  private func executablePath(for pid: pid_t) -> String? {
    // proc_pidpath writes a null-terminated absolute path into the provided buffer.
    var buffer = [CChar](repeating: 0, count: 4096)
    let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard result > 0 else {
      return nil
    }
    let utf8Bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: utf8Bytes, as: UTF8.self)
  }

  private func signingIdentity(from staticCode: SecStaticCode) -> CodeSigningIdentity? {
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

  // MARK: - CrabProxyHelperProtocol

  func enablePF(pfConf: String, certPath: String, reply: @escaping (Bool, String?) -> Void) {
    let confPath = NSTemporaryDirectory() + "crab-proxy-pf.conf"
    do {
      try pfConf.write(toFile: confPath, atomically: true, encoding: .utf8)
    } catch {
      reply(false, "Failed to write pf config: \(error.localizedDescription)")
      return
    }

    if !certPath.isEmpty {
      let certResult = runCommand(
        "/usr/bin/security",
        arguments: [
          "add-trusted-cert", "-d", "-r", "trustRoot",
          "-k", "/Library/Keychains/System.keychain", certPath,
        ]
      )
      if !certResult.success {
        reply(false, "Certificate install failed: \(certResult.error)")
        return
      }
    }

    let pfResult = runCommand(
      "/sbin/pfctl",
      arguments: ["-f", confPath, "-e"]
    )
    // pfctl -e returns 1 if pf is already enabled, which is fine
    reply(true, nil)
    _ = pfResult
  }

  func disablePF(reply: @escaping (Bool, String?) -> Void) {
    let result = runCommand(
      "/sbin/pfctl",
      arguments: ["-f", "/etc/pf.conf"]
    )
    if !result.success {
      reply(false, "pfctl disable failed: \(result.error)")
      return
    }
    reply(true, nil)
  }

  func installCert(certPath: String, reply: @escaping (Bool, String?) -> Void) {
    let result = runCommand(
      "/usr/bin/security",
      arguments: [
        "add-trusted-cert", "-d", "-r", "trustRoot",
        "-k", "/Library/Keychains/System.keychain", certPath,
      ]
    )
    reply(result.success, result.success ? nil : result.error)
  }

  func removeCert(commonName: String, reply: @escaping (Bool, String?) -> Void) {
    let result = runCommand(
      "/usr/bin/security",
      arguments: [
        "delete-certificate", "-c", commonName,
        "/Library/Keychains/System.keychain",
      ]
    )
    reply(result.success, result.success ? nil : result.error)
  }

  func checkCert(commonName: String, reply: @escaping (Bool) -> Void) {
    let result = runCommand(
      "/usr/bin/security",
      arguments: [
        "find-certificate", "-c", commonName,
        "/Library/Keychains/System.keychain",
      ]
    )
    reply(result.success)
  }

  // MARK: - Private

  private struct CommandResult {
    let success: Bool
    let output: String
    let error: String
  }

  private func runCommand(_ path: String, arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return CommandResult(success: false, output: "", error: error.localizedDescription)
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""

    return CommandResult(
      success: process.terminationStatus == 0,
      output: outStr.trimmingCharacters(in: .whitespacesAndNewlines),
      error: errStr.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.sangcomz.CrabProxyHelper")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
