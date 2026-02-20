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
}
