#if canImport(CCrabMitm)
import CCrabMitm
#endif
import Darwin
import Foundation

enum RustProxyError: Error, LocalizedError {
  case ffi(code: Int32, message: String)
  case internalState(String)

  var errorDescription: String? {
    switch self {
    case let .ffi(code, message):
      return "Rust FFI error(\(code)): \(message)"
    case let .internalState(message):
      return message
    }
  }
}

enum MapLocalSource {
  case file(path: String)
  case text(value: String)
}

struct MapLocalRuleConfig {
  var matcher: String
  var source: MapLocalSource
  var statusCode: UInt16
  var contentType: String?
}

struct MapRemoteRuleConfig {
  var matcher: String
  var destinationURL: String
}

struct StatusRewriteRuleConfig {
  var matcher: String
  var fromStatusCode: Int?
  var toStatusCode: UInt16
}

struct RuntimeRulesDump: Equatable {
  struct MapLocalSourceEntry: Equatable {
    enum Kind: String, Equatable {
      case file
      case text
    }

    var kind: Kind
    var value: String
  }

  struct MapLocalEntry: Equatable {
    var matcher: String
    var source: MapLocalSourceEntry
    var statusCode: UInt16
    var contentType: String?
  }

  struct MapRemoteEntry: Equatable {
    var matcher: String
    var destination: String
  }

  struct StatusRewriteEntry: Equatable {
    var matcher: String
    var fromStatusCode: UInt16?
    var toStatusCode: UInt16
  }

  var allowlist: [String]
  var mapLocal: [MapLocalEntry]
  var mapRemote: [MapRemoteEntry]
  var statusRewrite: [StatusRewriteEntry]
}

struct RuntimeEngineConfigDump: Equatable {
  struct InspectConfig: Equatable {
    var enabled: Bool
  }

  struct ThrottleConfig: Equatable {
    var enabled: Bool
    var latencyMs: UInt64
    var downstreamBytesPerSecond: UInt64
    var upstreamBytesPerSecond: UInt64
    var onlySelectedHosts: Bool
    var selectedHosts: [String]
  }

  struct ClientAllowlistConfig: Equatable {
    var enabled: Bool
    var ips: [String]
  }

  struct TransparentConfig: Equatable {
    var enabled: Bool
    var listenPort: UInt16
  }

  var running: Bool
  var listenAddress: String
  var inspect: InspectConfig
  var throttle: ThrottleConfig
  var clientAllowlist: ClientAllowlistConfig
  var transparent: TransparentConfig
}

enum CAKeyAlgorithm: UInt32 {
  case ecdsaP256 = 0
  case rsa2048 = 1
  case rsa4096 = 2
}

protocol ProxyEngineControlling: AnyObject {
  var onLog: (@Sendable (UInt8, String) -> Void)? { get set }

  func setListenAddress(_ value: String) throws
  func loadCA(certPath: String, keyPath: String) throws
  func setInspectEnabled(_ enabled: Bool) throws

  func setThrottleEnabled(_ enabled: Bool) throws
  func setThrottleLatencyMs(_ latencyMs: UInt64) throws
  func setThrottleDownstreamBytesPerSecond(_ bytesPerSecond: UInt64) throws
  func setThrottleUpstreamBytesPerSecond(_ bytesPerSecond: UInt64) throws
  func setThrottleOnlySelectedHosts(_ enabled: Bool) throws
  func clearThrottleSelectedHosts() throws
  func addThrottleSelectedHost(_ matcher: String) throws

  func setClientAllowlistEnabled(_ enabled: Bool) throws
  func clearClientAllowlist() throws
  func addClientAllowlistIP(_ ipAddress: String) throws

  func setTransparentEnabled(_ enabled: Bool) throws
  func setTransparentPort(_ port: UInt16) throws

  func clearRules() throws
  func clearDaemonLogs() throws
  func addAllowRule(_ matcher: String) throws
  func addMapLocalRule(_ rule: MapLocalRuleConfig) throws
  func addMapRemoteRule(_ rule: MapRemoteRuleConfig) throws
  func addStatusRewriteRule(_ rule: StatusRewriteRuleConfig) throws
  func dumpRules() throws -> RuntimeRulesDump
  func dumpConfig() throws -> RuntimeEngineConfigDump

  func startProxyRuntime() throws
  func stopProxyRuntime() throws
  func startCaptureRecording() throws
  func stopCaptureRecording() throws
  func shutdownDaemon() throws
  func isProxyRunning() -> Bool
  func isCaptureRunning() -> Bool
}

final class RustProxyEngine: @unchecked Sendable {
  var onLog: (@Sendable (UInt8, String) -> Void)? {
    didSet {
      if onLog == nil {
        stopLogStreaming()
      } else {
        startLogStreamingIfNeeded()
      }
    }
  }

  private var listenAddress: String
  private var inspectEnabled = true
  private var throttleEnabled = false
  private var throttleLatencyMs: UInt64 = 0
  private var throttleDownstreamBytesPerSecond: UInt64 = 0
  private var throttleUpstreamBytesPerSecond: UInt64 = 0
  private var throttleOnlySelectedHosts = false
  private var throttleSelectedHosts: [String] = []
  private var allowlistEnabled = false
  private var allowlistIPs: [String] = []
  private var transparentEnabled = false
  private var transparentPort: UInt16 = 8889

  private let crabdPath: String
  private let socketPath: String
  private let tokenPath: String
  private let principal = "app"

  private let logQueue = DispatchQueue(label: "CrabProxyMacApp.RustProxyEngine.log")
  private var logStreamingActive = false
  private var logTailCursor: UInt64 = 0

  init(listenAddress: String) throws {
    self.listenAddress = listenAddress

    crabdPath = try Self.resolveBinaries()

    let home = FileManager.default.homeDirectoryForCurrentUser
    let runDir = home
      .appendingPathComponent("Library")
      .appendingPathComponent("Application Support")
      .appendingPathComponent("CrabProxy")
      .appendingPathComponent("run")

    socketPath = runDir.appendingPathComponent("crabd.sock").path
    tokenPath = runDir.appendingPathComponent("app.token").path
  }

  deinit {
    stopLogStreaming()
  }

  func setListenAddress(_ value: String) throws {
    listenAddress = value
    _ = try invokeRPC(
      method: "engine.set_listen_addr",
      params: ["listen_addr": value]
    )
  }

  func setPort(_ value: UInt16) throws {
    let host: String
    if let index = listenAddress.lastIndex(of: ":") {
      host = String(listenAddress[..<index])
    } else {
      host = "127.0.0.1"
    }
    try setListenAddress("\(host):\(value)")
  }

  func loadCA(certPath: String, keyPath: String) throws {
    _ = try invokeRPC(
      method: "engine.load_ca",
      params: [
        "cert_path": certPath,
        "key_path": keyPath,
      ]
    )
  }

  static func generateCA(
    commonName: String,
    days: UInt32,
    certPath: String,
    keyPath: String,
    algorithm: CAKeyAlgorithm = .ecdsaP256
  ) throws {
#if canImport(CCrabMitm)
    let result = commonName.withCString { cn in
      certPath.withCString { cert in
        keyPath.withCString { key in
          crab_ca_generate_with_algorithm(cn, days, cert, key, algorithm.rawValue)
        }
      }
    }
    try check(result)
#else
    throw RustProxyError.internalState("CCrabMitm is unavailable for CA generation")
#endif
  }

  func setInspectEnabled(_ enabled: Bool) throws {
    inspectEnabled = enabled
    _ = try invokeRPC(
      method: "engine.set_inspect_enabled",
      params: ["enabled": enabled]
    )
  }

  func setThrottleEnabled(_ enabled: Bool) throws {
    throttleEnabled = enabled
    try pushThrottle()
  }

  func setThrottleLatencyMs(_ latencyMs: UInt64) throws {
    throttleLatencyMs = latencyMs
    try pushThrottle()
  }

  func setThrottleDownstreamBytesPerSecond(_ bytesPerSecond: UInt64) throws {
    throttleDownstreamBytesPerSecond = bytesPerSecond
    try pushThrottle()
  }

  func setThrottleUpstreamBytesPerSecond(_ bytesPerSecond: UInt64) throws {
    throttleUpstreamBytesPerSecond = bytesPerSecond
    try pushThrottle()
  }

  func setThrottleOnlySelectedHosts(_ enabled: Bool) throws {
    throttleOnlySelectedHosts = enabled
    try pushThrottle()
  }

  func clearThrottleSelectedHosts() throws {
    throttleSelectedHosts.removeAll(keepingCapacity: false)
    try pushThrottle()
  }

  func addThrottleSelectedHost(_ matcher: String) throws {
    throttleSelectedHosts.append(matcher)
    try pushThrottle()
  }

  func setClientAllowlistEnabled(_ enabled: Bool) throws {
    allowlistEnabled = enabled
    try pushClientAllowlist()
  }

  func clearClientAllowlist() throws {
    allowlistIPs.removeAll(keepingCapacity: false)
    try pushClientAllowlist()
  }

  func addClientAllowlistIP(_ ipAddress: String) throws {
    allowlistIPs.append(ipAddress)
    try pushClientAllowlist()
  }

  func setTransparentEnabled(_ enabled: Bool) throws {
    transparentEnabled = enabled
    try pushTransparent()
  }

  func setTransparentPort(_ port: UInt16) throws {
    transparentPort = port
    try pushTransparent()
  }

  func clearRules() throws {
    _ = try invokeRPC(method: "engine.rules_clear", params: [:])
  }

  func clearDaemonLogs() throws {
    let shouldResumeStreaming = logStreamingActive && onLog != nil
    stopLogStreamingAndDrain()

    let raw = try invokeRPC(method: "logs.clear", params: [:], ensureDaemon: false)
    if let payload = raw as? [String: Any], let next = payload["next_seq"] as? NSNumber {
      logTailCursor = next.uint64Value
    }

    if shouldResumeStreaming {
      startLogStreamingIfNeeded()
    }
  }

  func addAllowRule(_ matcher: String) throws {
    _ = try invokeRPC(
      method: "engine.rules_add_allow",
      params: ["matcher": matcher]
    )
  }

  func addMapLocalRule(_ rule: MapLocalRuleConfig) throws {
    switch rule.source {
    case let .file(path):
      var params: [String: Any] = [
        "matcher": rule.matcher,
        "file_path": path,
        "status_code": Int(rule.statusCode),
      ]
      if let contentType = rule.contentType {
        params["content_type"] = contentType
      }
      _ = try invokeRPC(method: "engine.rules_add_map_local_file", params: params)
    case let .text(value):
      var params: [String: Any] = [
        "matcher": rule.matcher,
        "text": value,
        "status_code": Int(rule.statusCode),
      ]
      if let contentType = rule.contentType {
        params["content_type"] = contentType
      }
      _ = try invokeRPC(method: "engine.rules_add_map_local_text", params: params)
    }
  }

  func addMapRemoteRule(_ rule: MapRemoteRuleConfig) throws {
    _ = try invokeRPC(
      method: "engine.rules_add_map_remote",
      params: [
        "matcher": rule.matcher,
        "destination": rule.destinationURL,
      ]
    )
  }

  func addStatusRewriteRule(_ rule: StatusRewriteRuleConfig) throws {
    _ = try invokeRPC(
      method: "engine.rules_add_status_rewrite",
      params: [
        "matcher": rule.matcher,
        "from_status_code": rule.fromStatusCode ?? -1,
        "to_status_code": Int(rule.toStatusCode),
      ]
    )
  }

  func dumpRules() throws -> RuntimeRulesDump {
    let raw = try invokeRPC(method: "engine.rules_dump", params: [:], ensureDaemon: false)
    return try parseRuntimeRulesDump(raw)
  }

  func dumpConfig() throws -> RuntimeEngineConfigDump {
    let raw = try invokeRPC(method: "engine.config_dump", params: [:], ensureDaemon: false)
    return try parseRuntimeConfigDump(raw)
  }

  func startProxyRuntime() throws {
    _ = try invokeRPC(method: "proxy.start", params: [:])
    startLogStreamingIfNeeded()
  }

  func stopProxyRuntime() throws {
    stopLogStreaming()
    _ = try invokeRPC(method: "proxy.stop", params: [:], ensureDaemon: false)
  }

  func startCaptureRecording() throws {
    do {
      _ = try invokeRPC(method: "capture.start", params: [:], ensureDaemon: false)
    } catch {
      if isMissingCaptureRPC(error) {
        // Older daemons don't expose capture.* yet. Keep legacy behavior compatible.
        return
      }
      throw error
    }
  }

  func stopCaptureRecording() throws {
    do {
      _ = try invokeRPC(method: "capture.stop", params: [:], ensureDaemon: false)
    } catch {
      if isMissingCaptureRPC(error) {
        return
      }
      throw error
    }
  }

  func shutdownDaemon() throws {
    stopLogStreaming()
    guard canConnectSocket() else { return }
    _ = try invokeRPC(method: "system.shutdown", params: [:], ensureDaemon: false)
  }

  func isProxyRunning() -> Bool {
    do {
      let raw = try invokeRPC(method: "proxy.status", params: [:], ensureDaemon: false)
      guard let payload = raw as? [String: Any], let status = payload["status"] as? String else {
        return false
      }
      return status == "running"
    } catch {
      return false
    }
  }

  func isCaptureRunning() -> Bool {
    do {
      let raw = try invokeRPC(method: "capture.status", params: [:], ensureDaemon: false)
      guard let payload = raw as? [String: Any], let status = payload["status"] as? String else {
        return false
      }
      return status == "running"
    } catch {
      if isMissingCaptureRPC(error) {
        return isProxyRunning()
      }
      return false
    }
  }

  private func pushThrottle() throws {
    _ = try invokeRPC(
      method: "engine.set_throttle",
      params: [
        "enabled": throttleEnabled,
        "latency_ms": throttleLatencyMs,
        "downstream_bps": throttleDownstreamBytesPerSecond,
        "upstream_bps": throttleUpstreamBytesPerSecond,
        "only_selected_hosts": throttleOnlySelectedHosts,
        "selected_hosts": throttleSelectedHosts,
      ]
    )
  }

  private func pushClientAllowlist() throws {
    _ = try invokeRPC(
      method: "engine.set_client_allowlist",
      params: [
        "enabled": allowlistEnabled,
        "ips": allowlistIPs,
      ]
    )
  }

  private func pushTransparent() throws {
    _ = try invokeRPC(
      method: "engine.set_transparent",
      params: [
        "enabled": transparentEnabled,
        "listen_port": Int(transparentPort),
      ]
    )
  }

  private func invokeRPC(
    method: String,
    params: [String: Any],
    ensureDaemon: Bool = true
  ) throws -> Any {
    if ensureDaemon {
      try ensureDaemonStarted()
    }

    let token = try readToken()
    let connection = try UnixLineConnection(path: socketPath)

    defer {
      connection.close()
    }

    let handshakeParams: [String: Any] = [
      "protocol_version": 1,
      "token": token,
      "client_type": principal,
    ]
    try connection.sendRequest(id: 1, method: "system.handshake", params: handshakeParams)
    let handshakeResponse = try connection.readResponse()
    try throwIfRPCError(handshakeResponse)

    try connection.sendRequest(id: 2, method: method, params: params)
    let response = try connection.readResponse()
    try throwIfRPCError(response)

    return response["result"] ?? NSNull()
  }

  private func parseRuntimeRulesDump(_ raw: Any) throws -> RuntimeRulesDump {
    guard let payload = raw as? [String: Any] else {
      throw RustProxyError.internalState("engine.rules_dump returned invalid payload")
    }

    let allowlist = (payload["allowlist"] as? [Any] ?? []).compactMap { $0 as? String }

    let mapLocalEntries = try (payload["map_local"] as? [Any] ?? []).map { item in
      guard let object = item as? [String: Any] else {
        throw RustProxyError.internalState("engine.rules_dump map_local entry is invalid")
      }
      guard let matcher = object["matcher"] as? String else {
        throw RustProxyError.internalState("engine.rules_dump map_local matcher is missing")
      }
      guard let sourceObject = object["source"] as? [String: Any] else {
        throw RustProxyError.internalState("engine.rules_dump map_local source is missing")
      }
      guard let sourceKindRaw = sourceObject["kind"] as? String,
            let sourceKind = RuntimeRulesDump.MapLocalSourceEntry.Kind(rawValue: sourceKindRaw)
      else {
        throw RustProxyError.internalState("engine.rules_dump map_local source kind is invalid")
      }
      guard let sourceValue = sourceObject["value"] as? String else {
        throw RustProxyError.internalState("engine.rules_dump map_local source value is missing")
      }
      guard let statusNumber = object["status_code"] as? NSNumber else {
        throw RustProxyError.internalState("engine.rules_dump map_local status_code is missing")
      }
      let contentType = object["content_type"] as? String
      return RuntimeRulesDump.MapLocalEntry(
        matcher: matcher,
        source: RuntimeRulesDump.MapLocalSourceEntry(kind: sourceKind, value: sourceValue),
        statusCode: UInt16(truncating: statusNumber),
        contentType: contentType
      )
    }

    let mapRemoteEntries = try (payload["map_remote"] as? [Any] ?? []).map { item in
      guard let object = item as? [String: Any] else {
        throw RustProxyError.internalState("engine.rules_dump map_remote entry is invalid")
      }
      guard let matcher = object["matcher"] as? String else {
        throw RustProxyError.internalState("engine.rules_dump map_remote matcher is missing")
      }
      guard let destination = object["destination"] as? String else {
        throw RustProxyError.internalState("engine.rules_dump map_remote destination is missing")
      }
      return RuntimeRulesDump.MapRemoteEntry(matcher: matcher, destination: destination)
    }

    let statusRewriteEntries = try (payload["status_rewrite"] as? [Any] ?? []).map { item in
      guard let object = item as? [String: Any] else {
        throw RustProxyError.internalState("engine.rules_dump status_rewrite entry is invalid")
      }
      guard let matcher = object["matcher"] as? String else {
        throw RustProxyError.internalState("engine.rules_dump status_rewrite matcher is missing")
      }
      guard let toStatusNumber = object["to_status_code"] as? NSNumber else {
        throw RustProxyError.internalState("engine.rules_dump status_rewrite to_status_code is missing")
      }

      let fromStatusNumber = object["from_status_code"] as? NSNumber
      return RuntimeRulesDump.StatusRewriteEntry(
        matcher: matcher,
        fromStatusCode: fromStatusNumber.map { UInt16(truncating: $0) },
        toStatusCode: UInt16(truncating: toStatusNumber)
      )
    }

    return RuntimeRulesDump(
      allowlist: allowlist,
      mapLocal: mapLocalEntries,
      mapRemote: mapRemoteEntries,
      statusRewrite: statusRewriteEntries
    )
  }

  private func parseRuntimeConfigDump(_ raw: Any) throws -> RuntimeEngineConfigDump {
    guard let payload = raw as? [String: Any] else {
      throw RustProxyError.internalState("engine.config_dump returned invalid payload")
    }

    let running = try boolValue(payload["running"], key: "running")
    let listenAddress = try stringValue(payload["listen_addr"], key: "listen_addr")

    guard let inspectObject = payload["inspect"] as? [String: Any] else {
      throw RustProxyError.internalState("engine.config_dump inspect is missing")
    }
    guard let throttleObject = payload["throttle"] as? [String: Any] else {
      throw RustProxyError.internalState("engine.config_dump throttle is missing")
    }
    guard let clientAllowlistObject = payload["client_allowlist"] as? [String: Any] else {
      throw RustProxyError.internalState("engine.config_dump client_allowlist is missing")
    }
    guard let transparentObject = payload["transparent"] as? [String: Any] else {
      throw RustProxyError.internalState("engine.config_dump transparent is missing")
    }

    let inspect = RuntimeEngineConfigDump.InspectConfig(
      enabled: try boolValue(inspectObject["enabled"], key: "inspect.enabled")
    )

    let throttle = RuntimeEngineConfigDump.ThrottleConfig(
      enabled: try boolValue(throttleObject["enabled"], key: "throttle.enabled"),
      latencyMs: try uint64Value(throttleObject["latency_ms"], key: "throttle.latency_ms"),
      downstreamBytesPerSecond: try uint64Value(
        throttleObject["downstream_bps"],
        key: "throttle.downstream_bps"
      ),
      upstreamBytesPerSecond: try uint64Value(
        throttleObject["upstream_bps"],
        key: "throttle.upstream_bps"
      ),
      onlySelectedHosts: try boolValue(
        throttleObject["only_selected_hosts"],
        key: "throttle.only_selected_hosts"
      ),
      selectedHosts: (throttleObject["selected_hosts"] as? [Any] ?? []).compactMap { $0 as? String }
    )

    let clientAllowlist = RuntimeEngineConfigDump.ClientAllowlistConfig(
      enabled: try boolValue(clientAllowlistObject["enabled"], key: "client_allowlist.enabled"),
      ips: (clientAllowlistObject["ips"] as? [Any] ?? []).compactMap { $0 as? String }
    )

    let transparent = RuntimeEngineConfigDump.TransparentConfig(
      enabled: try boolValue(transparentObject["enabled"], key: "transparent.enabled"),
      listenPort: try uint16Value(transparentObject["listen_port"], key: "transparent.listen_port")
    )

    return RuntimeEngineConfigDump(
      running: running,
      listenAddress: listenAddress,
      inspect: inspect,
      throttle: throttle,
      clientAllowlist: clientAllowlist,
      transparent: transparent
    )
  }

  private func stringValue(_ raw: Any?, key: String) throws -> String {
    if let value = raw as? String {
      return value
    }
    if let number = raw as? NSNumber {
      return number.stringValue
    }
    throw RustProxyError.internalState("engine.config_dump \(key) is invalid")
  }

  private func boolValue(_ raw: Any?, key: String) throws -> Bool {
    if let value = raw as? Bool {
      return value
    }
    if let number = raw as? NSNumber {
      return number.boolValue
    }
    if let value = raw as? String {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if normalized == "true" || normalized == "1" { return true }
      if normalized == "false" || normalized == "0" { return false }
    }
    throw RustProxyError.internalState("engine.config_dump \(key) is invalid")
  }

  private func uint64Value(_ raw: Any?, key: String) throws -> UInt64 {
    if let number = raw as? NSNumber {
      return number.uint64Value
    }
    if let value = raw as? String,
       let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return parsed
    }
    throw RustProxyError.internalState("engine.config_dump \(key) is invalid")
  }

  private func uint16Value(_ raw: Any?, key: String) throws -> UInt16 {
    let value = try uint64Value(raw, key: key)
    guard value <= UInt64(UInt16.max) else {
      throw RustProxyError.internalState("engine.config_dump \(key) is out of range")
    }
    return UInt16(value)
  }

  private func throwIfRPCError(_ response: [String: Any]) throws {
    guard let errorPayload = response["error"] as? [String: Any] else {
      return
    }

    let code = (errorPayload["code"] as? NSNumber)?.intValue ?? -1
    let message = (errorPayload["message"] as? String) ?? "Unknown RPC error"
    throw RustProxyError.internalState("RPC error(\(code)): \(message)")
  }

  private func isMissingCaptureRPC(_ error: Error) -> Bool {
    guard case let RustProxyError.internalState(message) = error else {
      return false
    }
    return message.contains("unknown method: capture.")
  }

  private func readToken() throws -> String {
    let raw: String
    do {
      raw = try String(contentsOfFile: tokenPath, encoding: .utf8)
    } catch {
      throw RustProxyError.internalState(
        "failed to read token file (\(tokenPath)): \(error.localizedDescription)"
      )
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw RustProxyError.internalState("Token file is empty: \(tokenPath)")
    }
    return value
  }

  private func ensureDaemonStarted() throws {
    if canConnectSocket() {
      return
    }

    do {
      _ = try runDetached(
        executablePath: crabdPath,
        arguments: ["serve"]
      )
    } catch {
      throw RustProxyError.internalState(
        "failed to launch daemon (\(crabdPath)): \(error.localizedDescription)"
      )
    }

    let timeout = Date().addingTimeInterval(3.0)
    while Date() < timeout {
      if canConnectSocket() {
        return
      }
      usleep(50_000)
    }

    throw RustProxyError.internalState("daemon socket did not become available: \(socketPath)")
  }

  private func canConnectSocket() -> Bool {
    do {
      let connection = try UnixLineConnection(path: socketPath)
      connection.close()
      return true
    } catch {
      return false
    }
  }

  private func startLogStreamingIfNeeded() {
    guard onLog != nil else { return }
    guard !logStreamingActive else { return }
    logStreamingActive = true

    logQueue.async { [weak self] in
      guard let self else { return }

      var cursor = self.logTailCursor
      while self.logStreamingActive {
        autoreleasepool {
          do {
            let raw = try self.invokeRPC(
              method: "logs.tail",
              params: ["after_seq": cursor, "limit": 200],
              ensureDaemon: false
            )
            if let payload = raw as? [String: Any] {
              if let next = payload["next_seq"] as? NSNumber {
                cursor = next.uint64Value
              }
              if let records = payload["records"] as? [[String: Any]] {
                for record in records {
                  guard let message = record["message"] as? String else { continue }
                  let levelValue = (record["level"] as? NSNumber)?.uint8Value ?? 2
                  self.onLog?(levelValue, message)
                }
              }
              self.logTailCursor = cursor
            }
          } catch {
            // No-op: keep polling; daemon may be down during stop/restart windows.
          }
        }

        usleep(200_000)
      }
    }
  }

  private func stopLogStreaming() {
    logStreamingActive = false
  }

  private func stopLogStreamingAndDrain() {
    let wasActive = logStreamingActive
    logStreamingActive = false
    guard wasActive else { return }

    // Wait until the current polling loop iteration exits so clear operations can
    // resync the cursor without the previous batch racing in behind it.
    logQueue.sync { }
  }

  private static func resolveBinaries() throws -> String {
    let fm = FileManager.default

    if let resourcesURL = Bundle.main.resourceURL {
      let crabd = resourcesURL.appendingPathComponent("crabd").path
      if fm.isExecutableFile(atPath: crabd) {
        return crabd
      }
    }

    let fallbackRoot = URL(
      fileURLWithPath: "../crab-mitm/target/debug",
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let fallbackCrabd = fallbackRoot.appendingPathComponent("crabd").path
    if fm.isExecutableFile(atPath: fallbackCrabd) {
      return fallbackCrabd
    }

    throw RustProxyError.internalState("crabd binary is missing from app resources")
  }

#if canImport(CCrabMitm)
  private static func check(_ result: CrabResult) throws {
    if result.code == CRAB_OK {
      if let message = result.message {
        crab_free_string(message)
      }
      return
    }

    let message: String
    if let raw = result.message {
      message = String(cString: raw)
      crab_free_string(raw)
    } else {
      message = "unknown error"
    }

    throw RustProxyError.ffi(code: result.code, message: message)
  }
#endif
}

extension RustProxyEngine: ProxyEngineControlling {}

@discardableResult
private func runDetached(executablePath: String, arguments: [String]) throws -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executablePath)
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  return process
}

private final class UnixLineConnection {
  private static let ioTimeoutMilliseconds: Int32 = 4_000
  private var fd: Int32 = -1
  private var readBuffer = Data()

  init(path: String) throws {
    let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      throw RustProxyError.internalState("socket(AF_UNIX) failed: \(Self.lastErrnoString())")
    }

    do {
      try Self.connect(fd: socketFD, path: path)
      fd = socketFD
    } catch {
      Darwin.close(socketFD)
      throw error
    }
  }

  deinit {
    close()
  }

  func close() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
  }

  func sendRequest(id: Int, method: String, params: [String: Any]) throws {
    guard fd >= 0 else {
      throw RustProxyError.internalState("socket connection is closed")
    }

    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var line = data
    line.append(0x0A)
    try writeAll(line)
  }

  func readResponse() throws -> [String: Any] {
    let line = try readLine()
    let object = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw RustProxyError.internalState("invalid RPC response payload")
    }
    return payload
  }

  private func readLine() throws -> Data {
    guard fd >= 0 else {
      throw RustProxyError.internalState("socket connection is closed")
    }

    while true {
      if let newline = readBuffer.firstIndex(of: 0x0A) {
        let line = readBuffer.subdata(in: 0..<newline)
        readBuffer.removeSubrange(0...newline)
        return line
      }

      try waitReadable()

      var chunk = [UInt8](repeating: 0, count: 4096)
      let readCount = Darwin.read(fd, &chunk, chunk.count)
      if readCount > 0 {
        readBuffer.append(contentsOf: chunk.prefix(Int(readCount)))
        continue
      }
      if readCount == 0 {
        throw RustProxyError.internalState("socket closed while waiting for response")
      }
      let code = errno
      if code == EINTR {
        continue
      }
      if code == EAGAIN || code == EWOULDBLOCK || code == ETIMEDOUT {
        throw RustProxyError.internalState("RPC socket timed out while waiting for response")
      }
      throw RustProxyError.internalState("socket read failed: \(Self.lastErrnoString(code))")
    }
  }

  private func writeAll(_ data: Data) throws {
    guard fd >= 0 else {
      throw RustProxyError.internalState("socket connection is closed")
    }
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
        if written > 0 {
          offset += written
          continue
        }
        let code = errno
        if code == EINTR {
          continue
        }
        if code == EAGAIN || code == EWOULDBLOCK || code == ETIMEDOUT {
          throw RustProxyError.internalState("RPC socket timed out while writing request")
        }
        throw RustProxyError.internalState("socket write failed: \(Self.lastErrnoString(code))")
      }
    }
  }

  private func waitReadable() throws {
    guard fd >= 0 else {
      throw RustProxyError.internalState("socket connection is closed")
    }
    var descriptor = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
      let polled = Darwin.poll(&descriptor, 1, Self.ioTimeoutMilliseconds)
      if polled > 0 {
        return
      }
      if polled == 0 {
        throw RustProxyError.internalState("RPC socket timed out while waiting for response")
      }
      let code = errno
      if code == EINTR {
        continue
      }
      throw RustProxyError.internalState("poll() failed: \(Self.lastErrnoString(code))")
    }
  }

  private static func connect(fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
#if os(macOS)
    addr.sun_len = __uint8_t(MemoryLayout<sockaddr_un>.size)
#endif

    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < maxPathLength else {
      throw RustProxyError.internalState("socket path is too long: \(path)")
    }

    withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { cString in
        cString.initialize(repeating: 0, count: maxPathLength)
        path.withCString { source in
          _ = strlcpy(cString, source, maxPathLength)
        }
      }
    }

    let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    if result != 0 {
      throw RustProxyError.internalState("connect(\(path)) failed: \(lastErrnoString())")
    }
  }

  private static func lastErrnoString(_ code: Int32 = errno) -> String {
    guard let cString = strerror(code) else {
      return "errno \(code)"
    }
    return String(cString: cString)
  }
}

private func lastErrnoString() -> String {
  let code = errno
  guard let cString = strerror(code) else {
    return "errno \(code)"
  }
  return String(cString: cString)
}
