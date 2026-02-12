import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate, CrabProxyHelperProtocol {

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)
    newConnection.exportedObject = self
    newConnection.resume()
    return true
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
