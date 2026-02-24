import AppKit
import Darwin
import Foundation

private enum MCPHttpServiceError: Error, LocalizedError {
  case executableMissing(String)

  var errorDescription: String? {
    switch self {
    case .executableMissing(let name):
      return "\(name) binary is missing from app resources"
    }
  }
}

@MainActor
final class MCPHttpService: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var endpoint: String?
  @Published private(set) var tokenFilePath: String?
  @Published private(set) var lastError: String?
  @Published var port: UInt16 = 3847

  private let bindHost = "127.0.0.1"
  private var process: Process?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var isStopping = false

  init() {
    tokenFilePath = Self.defaultTokenPath()
    endpoint = Self.endpointURL(host: bindHost, port: port)
  }

  func start(ensureDaemon: Bool = true) {
    guard !isRunning else { return }

    do {
      let runDir = try Self.runDirectoryURL(createIfMissing: true)
      let socketPath = runDir.appendingPathComponent("crabd.sock").path
      let tokenPath = runDir.appendingPathComponent("mcp.token").path
      let crabdPath = try Self.resolveExecutable(named: "crabd")
      let mcpPath = try Self.resolveExecutable(named: "crab-mcp")

      // If the app was relaunched or lost state, stale crab-mcp instances can remain
      // and force a fallback port (3848+). Clean matching HTTP servers first so the
      // new process owns the configured port and token lifecycle.
      try Self.terminateConflictingHTTPServers(socketPath: socketPath, tokenPath: tokenPath)

      let process = Process()
      process.executableURL = URL(fileURLWithPath: mcpPath)

      var args: [String] = [
        "--transport", "http",
        "--http-bind", bindHost,
        "--http-port", String(port),
        "--principal", "mcp",
        "--socket", socketPath,
        "--token-path", tokenPath,
        "--daemon-path", crabdPath,
      ]
      if !ensureDaemon {
        args += ["--ensure-daemon", "false"]
      }
      process.arguments = args
      process.standardInput = FileHandle.nullDevice

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      installReadHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

      isStopping = false
      process.terminationHandler = { [weak self] proc in
        Task { @MainActor in
          guard let self else { return }
          let intentionalStop = self.isStopping
          self.isStopping = false
          self.process = nil
          self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
          self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
          self.stdoutPipe = nil
          self.stderrPipe = nil
          self.isRunning = false

          if !intentionalStop && proc.terminationStatus != 0 {
            self.lastError = "MCP exited with status \(proc.terminationStatus)"
          }
        }
      }

      try process.run()

      self.process = process
      self.stdoutPipe = stdoutPipe
      self.stderrPipe = stderrPipe
      self.tokenFilePath = tokenPath
      self.endpoint = Self.endpointURL(host: bindHost, port: port)
      self.lastError = nil
      self.isRunning = true
    } catch {
      self.isRunning = false
      self.lastError = error.localizedDescription
    }
  }

  func stop() {
    guard let process else {
      isRunning = false
      return
    }

    isStopping = true
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil

    if process.isRunning {
      process.terminate()

      let deadline = Date().addingTimeInterval(2.0)
      while process.isRunning && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      }

      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }

    self.process = nil
    self.stdoutPipe = nil
    self.stderrPipe = nil
    self.isRunning = false
  }

  func copyEndpointToPasteboard() {
    guard let endpoint else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(endpoint, forType: .string)
  }

  func copyTokenToPasteboard() {
    guard let tokenFilePath else { return }
    guard let raw = try? String(contentsOfFile: tokenFilePath, encoding: .utf8) else { return }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(token, forType: .string)
  }

  private func installReadHandlers(stdoutPipe: Pipe, stderrPipe: Pipe) {
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in
        self?.consumeOutput(data: data, isError: false)
      }
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in
        self?.consumeOutput(data: data, isError: true)
      }
    }
  }

  private func consumeOutput(data: Data, isError: Bool) {
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
    let lines = text.split(whereSeparator: \.isNewline)
    for rawLine in lines {
      let line = String(rawLine)
      if let endpoint = Self.extractEndpoint(from: line) {
        self.endpoint = endpoint
      }
      if Self.isErrorLine(line, fromErrorStream: isError) {
        self.lastError = line
      } else if line.localizedCaseInsensitiveContains("listening on http://") {
        // Clear stale error text when the server becomes healthy.
        self.lastError = nil
      }
    }
  }

  private static func isErrorLine(_ line: String, fromErrorStream: Bool) -> Bool {
    let severityPattern = #"\b(error|failed|fatal|panic|denied|refused)\b"#
    if line.range(of: severityPattern, options: [.regularExpression, .caseInsensitive]) != nil {
      return true
    }
    if fromErrorStream {
      // Keep warning-level stderr visible as non-fatal messages in logs, not red errors in UI.
      return false
    }
    return false
  }

  private static func extractEndpoint(from line: String) -> String? {
    guard let range = line.range(
      of: #"http://[^\s"]+/mcp"#,
      options: .regularExpression
    ) else {
      return nil
    }
    return String(line[range])
  }

  private static func endpointURL(host: String, port: UInt16) -> String {
    "http://\(host):\(port)/mcp"
  }

  private static func defaultTokenPath() -> String? {
    guard let runDir = try? runDirectoryURL(createIfMissing: false) else { return nil }
    return runDir.appendingPathComponent("mcp.token").path
  }

  private static func runDirectoryURL(createIfMissing: Bool) throws -> URL {
    let runDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Application Support")
      .appendingPathComponent("CrabProxy")
      .appendingPathComponent("run")

    if createIfMissing {
      try FileManager.default.createDirectory(
        at: runDir,
        withIntermediateDirectories: true
      )
    }

    return runDir
  }

  private static func resolveExecutable(named name: String) throws -> String {
    let fm = FileManager.default

    if let resourcesURL = Bundle.main.resourceURL {
      let candidate = resourcesURL.appendingPathComponent(name).path
      if fm.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    let fallbackRoot = URL(
      fileURLWithPath: "../crab-mitm/target/debug",
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let fallback = fallbackRoot.appendingPathComponent(name).path
    if fm.isExecutableFile(atPath: fallback) {
      return fallback
    }

    throw MCPHttpServiceError.executableMissing(name)
  }

  private static func terminateConflictingHTTPServers(
    socketPath: String,
    tokenPath: String
  ) throws {
    let pids = try findMatchingHTTPServerPIDs(socketPath: socketPath, tokenPath: tokenPath)
    guard !pids.isEmpty else { return }

    for pid in pids {
      _ = Darwin.kill(pid, SIGTERM)
    }

    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
      let alive = pids.contains { isProcessAlive($0) }
      if !alive {
        break
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    for pid in pids where isProcessAlive(pid) {
      _ = Darwin.kill(pid, SIGKILL)
    }
  }

  private static func findMatchingHTTPServerPIDs(
    socketPath: String,
    tokenPath: String
  ) throws -> [pid_t] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()

    // Drain stdout before waiting. Waiting first can deadlock if `ps` output fills the pipe
    // buffer, which would freeze the UI because `start()` runs on the main actor.
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "MCPHttpService",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "ps failed with status \(process.terminationStatus)"]
      )
    }

    let text = String(data: data, encoding: .utf8) ?? ""
    if text.isEmpty { return [] }

    let socketMarker = "--socket \(socketPath)"
    let tokenMarker = "--token-path \(tokenPath)"

    return text
      .split(whereSeparator: \.isNewline)
      .compactMap { rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        guard let split = line.firstIndex(where: \.isWhitespace) else { return nil }

        let pidText = line[..<split]
        let commandStart = line[split...].drop(while: \.isWhitespace)
        let command = String(commandStart)
        guard command.contains("crab-mcp") else { return nil }
        guard command.contains("--transport http") else { return nil }
        guard command.contains("--principal mcp") else { return nil }
        guard command.contains(socketMarker) else { return nil }
        guard command.contains(tokenMarker) else { return nil }

        return pid_t(pidText) ?? 0
      }
      .filter { $0 > 0 }
  }

  private static func isProcessAlive(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 {
      return true
    }
    return errno == EPERM
  }
}
