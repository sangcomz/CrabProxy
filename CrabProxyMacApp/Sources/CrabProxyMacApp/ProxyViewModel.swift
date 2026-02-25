import Combine
import CFNetwork
import Foundation
import Network

private enum ProxyViewModelError: Error, LocalizedError {
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .invalidValue(let message):
      return message
    }
  }
}

@MainActor
final class ProxyViewModel: ObservableObject {
  enum StatusCodeCategory: String, CaseIterable, Hashable, Identifiable {
    case info = "1xx"
    case success = "2xx"
    case redirect = "3xx"
    case clientError = "4xx"
    case serverError = "5xx"

    var id: String { rawValue }

    func contains(_ statusCode: Int) -> Bool {
      switch self {
      case .info:
        return (100..<200).contains(statusCode)
      case .success:
        return (200..<300).contains(statusCode)
      case .redirect:
        return (300..<400).contains(statusCode)
      case .clientError:
        return (400..<500).contains(statusCode)
      case .serverError:
        return (500..<600).contains(statusCode)
      }
    }
  }

  struct DomainGroup: Hashable, Identifiable {
    let domain: String
    let count: Int
    let hasMacOS: Bool
    let hasMobile: Bool

    var id: String { domain }
  }

  private struct ReplayHeader: Sendable {
    let name: String
    let value: String
  }

  private struct ReplayRequestDraft: Sendable {
    let method: String
    let url: URL
    let headers: [ReplayHeader]
    let bodyData: Data?
    let redactedHeaderCount: Int
    let omittedBinaryBody: Bool
  }

  private struct PersistedMapLocalRule: Codable {
    var isEnabled: Bool?
    var matcher: String
    var sourceType: String
    var sourceValue: String
    var statusCode: String
    var contentType: String
  }

  private struct PersistedMapRemoteRule: Codable {
    var isEnabled: Bool?
    var matcher: String
    var destinationURL: String
  }

  private struct PersistedStatusRewriteRule: Codable {
    var isEnabled: Bool?
    var matcher: String
    var fromStatusCode: String
    var toStatusCode: String
  }

  private struct CanonicalMapLocalRule: Equatable {
    var matcher: String
    var sourceType: RuleSourceType
    var sourceValue: String
    var statusCode: UInt16
    var contentType: String?
  }

  private struct CanonicalMapRemoteRule: Equatable {
    var matcher: String
    var destinationURL: String
  }

  private struct CanonicalStatusRewriteRule: Equatable {
    var matcher: String
    var fromStatusCode: UInt16?
    var toStatusCode: UInt16
  }

  let certPortalURL = "http://crab-proxy.local/"
  private let listenPort: UInt16 = 8888
  @Published var allowLANConnections = true {
    didSet {
      applyAllowLANConnectionsIfRunning(oldValue: oldValue)
    }
  }
  @Published var lanClientAllowlist: [String] = [] {
    didSet {
      let normalized = Self.normalizedLANClientAllowlist(lanClientAllowlist)
      if lanClientAllowlist != normalized {
        lanClientAllowlist = normalized
        return
      }
      applyLANClientAllowlistIfRunning(oldValue: oldValue)
    }
  }
  @Published private(set) var pendingLANAccessRequestIP: String?
  var listenAddress: String {
    let host = allowLANConnections ? "0.0.0.0" : "127.0.0.1"
    return "\(host):\(listenPort)"
  }
  @Published private(set) var caCertPath = ""
  @Published private(set) var caStatusText = "Preparing internal CA"
  @Published var inspectBodies = true {
    didSet {
      applyInspectBodiesIfRunning(oldValue: oldValue)
    }
  }
  @Published var throttleEnabled = false {
    didSet {
      applyThrottleIfRunning(oldValue: oldValue)
    }
  }
  @Published var throttleLatencyMs = 0 {
    didSet {
      let normalized = Self.normalizedNonNegativeInt(throttleLatencyMs)
      if throttleLatencyMs != normalized {
        throttleLatencyMs = normalized
        return
      }
      applyThrottleLatencyIfRunning(oldValue: oldValue)
    }
  }
  @Published var throttleDownstreamKbps = 0 {
    didSet {
      let normalized = Self.normalizedNonNegativeInt(throttleDownstreamKbps)
      if throttleDownstreamKbps != normalized {
        throttleDownstreamKbps = normalized
        return
      }
      applyThrottleDownstreamIfRunning(oldValue: oldValue)
    }
  }
  @Published var throttleUpstreamKbps = 0 {
    didSet {
      let normalized = Self.normalizedNonNegativeInt(throttleUpstreamKbps)
      if throttleUpstreamKbps != normalized {
        throttleUpstreamKbps = normalized
        return
      }
      applyThrottleUpstreamIfRunning(oldValue: oldValue)
    }
  }
  @Published var throttleOnlySelectedHosts = false {
    didSet {
      applyThrottleOnlySelectedHostsIfRunning(oldValue: oldValue)
    }
  }
  @Published var throttleSelectedHosts: [String] = [] {
    didSet {
      let normalized = Self.normalizedThrottleHosts(throttleSelectedHosts)
      if throttleSelectedHosts != normalized {
        throttleSelectedHosts = normalized
        return
      }
      applyThrottleSelectedHostsIfRunning(oldValue: oldValue)
    }
  }
  @Published private(set) var isCaptureEnabled = false
  @Published private(set) var isRuntimeRunning = false
  @Published var statusText = ProxyViewModel.proxyStoppedStatusSummary
  @Published var visibleURLFilter = "" {
    didSet { rebuildFilteredLogs() }
  }
  @Published var statusCodeFilter: Set<StatusCodeCategory> = [] {
    didSet { rebuildFilteredLogs() }
  }
  @Published private(set) var macSystemProxyEnabled = false
  @Published private(set) var macSystemProxyServiceText = "Unknown"
  @Published private(set) var macSystemProxyStateText = "Unknown"
  @Published var transparentProxyEnabled = false
  @Published private(set) var isApplyingTransparentProxy = false
  @Published private(set) var transparentProxyStateText = "OFF"
  @Published private(set) var isApplyingMacSystemProxy = false
  @Published private(set) var caCertInstalledInKeychain = false
  @Published private(set) var isInstallingCACert = false
  @Published private(set) var helperInstalled = false
  @Published private(set) var isInstallingHelper = false
  @Published private(set) var logs: [ProxyLogEntry] = []
  @Published private(set) var filteredLogs: [ProxyLogEntry] = []
  @Published var selectedLogID: ProxyLogEntry.ID?
  @Published var stagedMapLocalRule: MapLocalRuleInput?
  @Published var stagedMapRemoteRule: MapRemoteRuleInput?
  @Published var stagedAllowRule: AllowRuleInput?
  @Published var stagedStatusRewriteRule: StatusRewriteRuleInput?
  @Published var allowRules: [AllowRuleInput] = []
  @Published var mapLocalRules: [MapLocalRuleInput] = []
  @Published var mapRemoteRules: [MapRemoteRuleInput] = []
  @Published var statusRewriteRules: [StatusRewriteRuleInput] = []

  private let runtimeCoordinator: ProxyRuntimeCoordinator
  private let logStore = ProxyLogStore(maxLogEntries: 800)
  private let ruleManager = ProxyRuleManager()
  private static let allowRulesDefaultsKey = "CrabProxyMacApp.allowRules"
  private static let mapLocalRulesDefaultsKey = "CrabProxyMacApp.mapLocalRules.v1"
  private static let mapRemoteRulesDefaultsKey = "CrabProxyMacApp.mapRemoteRules.v1"
  private static let statusRewriteRulesDefaultsKey = "CrabProxyMacApp.statusRewriteRules.v1"
  private static let allowLANConnectionsDefaultsKey = "CrabProxyMacApp.network.allowLANConnections.v1"
  private static let lanClientAllowlistDefaultsKey =
    "CrabProxyMacApp.network.lanClientAllowlist.v1"
  private static let throttleEnabledDefaultsKey = "CrabProxyMacApp.throttle.enabled.v1"
  private static let throttleLatencyMsDefaultsKey = "CrabProxyMacApp.throttle.latencyMs.v1"
  private static let throttleDownstreamKbpsDefaultsKey = "CrabProxyMacApp.throttle.downstreamKbps.v1"
  private static let throttleUpstreamKbpsDefaultsKey = "CrabProxyMacApp.throttle.upstreamKbps.v1"
  private static let throttleOnlySelectedHostsDefaultsKey =
    "CrabProxyMacApp.throttle.onlySelectedHosts.v1"
  private static let throttleSelectedHostsDefaultsKey =
    "CrabProxyMacApp.throttle.selectedHosts.v1"
  private let internalCACommonName = "Crab Proxy Internal Root CA"
  private let internalCADays: UInt32 = 3650
  private let logFlushIntervalNanoseconds: UInt64 = 50_000_000
  private let runtimeRulesSyncIntervalNanoseconds: UInt64 = 1_000_000_000
  private let runtimeConfigSyncIntervalNanoseconds: UInt64 = 1_000_000_000
  private let runtimeStatusSyncIntervalNanoseconds: UInt64 = 700_000_000
  private let transparentProxyPort: UInt16 = 8889
  private let clientAppResolutionBatchSize = 24
  private let maxClientAppResolutionAttempts = 2
  private static let replayExcludedHeaders: Set<String> = [
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "upgrade"
  ]
  private static let replayMethodTokenCharacters = CharacterSet(
    charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  )
  private let caCertService: any CACertServicing
  private let pfService: any PFServicing
  private let systemProxyService: any MacSystemProxyServicing
  let mcpHttpService = MCPHttpService()
  private let clientAppResolver = LocalClientAppResolver(listenPort: 8888)
  private var pendingLogEvents: [(level: UInt8, message: String)] = []
  private var pendingClientAppResolutionIDs: Set<ProxyLogEntry.ID> = []
  private var clientAppResolutionAttempts: [ProxyLogEntry.ID: Int] = [:]
  private var suppressIncomingLogs = false
  private var suppressIncomingLogsGeneration: UInt64 = 0
  private var logFlushTask: Task<Void, Never>?
  private var listenAddressApplyTask: Task<Void, Never>?
  private var lanClientAllowlistApplyTask: Task<Void, Never>?
  private var inspectBodiesApplyTask: Task<Void, Never>?
  private var throttleApplyTask: Task<Void, Never>?
  private var runtimeRulesSyncTask: Task<Void, Never>?
  private var runtimeConfigSyncTask: Task<Void, Never>?
  private var runtimeStatusSyncTask: Task<Void, Never>?
  private var runtimeBootstrapTask: Task<Void, Never>?
  private var pendingLANAccessQueue: [String] = []
  private var dismissedLANAccessIPs: Set<String> = []
  private var cancellables: Set<AnyCancellable> = []
  private var lastObservedRuntimeRunning: Bool?
  private var lastObservedCaptureRunning: Bool?
  private var lastObservedRuntimeRulesDump: RuntimeRulesDump?
  private var lastObservedRuntimeConfigDump: RuntimeEngineConfigDump?
  private var suppressExternalRuntimeConfigApply = false

  private var engine: (any ProxyEngineControlling)? {
    runtimeCoordinator.engine
  }

  private static let proxyReadyStatusSummary = "Proxy ready • Capture stopped"
  private static let proxyStoppedStatusSummary = "Proxy stopped • Capture stopped"
  private static let proxyRunningCaptureOnStatusSummary = "Proxy running • Capture running"
  private static let proxyRunningCaptureOffStatusSummary = "Proxy running • Capture stopped"

  private static func runtimeStatusSummary(proxyRunning: Bool, captureRunning: Bool) -> String {
    if !proxyRunning {
      return proxyStoppedStatusSummary
    }
    return captureRunning ? proxyRunningCaptureOnStatusSummary : proxyRunningCaptureOffStatusSummary
  }

  private static func isRuntimeStatusSummary(_ value: String) -> Bool {
    switch value {
    case proxyReadyStatusSummary,
         proxyStoppedStatusSummary,
         proxyRunningCaptureOnStatusSummary,
         proxyRunningCaptureOffStatusSummary:
      return true
    default:
      return false
    }
  }

  init(
    systemProxyService: any MacSystemProxyServicing = LiveMacSystemProxyService(),
    pfService: any PFServicing = LivePFService(),
    caCertService: any CACertServicing = LiveCACertService(),
    engineFactory: @escaping (String) throws -> any ProxyEngineControlling = {
      try RustProxyEngine(listenAddress: $0)
    }
  ) {
    self.caCertService = caCertService
    self.pfService = pfService
    self.systemProxyService = systemProxyService
    self.runtimeCoordinator = ProxyRuntimeCoordinator(engineFactory: engineFactory)
    allowRules = Self.loadAllowRules()
    mapLocalRules = Self.loadMapLocalRules()
    mapRemoteRules = Self.loadMapRemoteRules()
    statusRewriteRules = Self.loadStatusRewriteRules()
    allowLANConnections = Self.loadAllowLANConnections()
    lanClientAllowlist = Self.loadLANClientAllowlist()
    throttleEnabled = Self.loadThrottleEnabled()
    throttleLatencyMs = Self.loadThrottleLatencyMs()
    throttleDownstreamKbps = Self.loadThrottleDownstreamKbps()
    throttleUpstreamKbps = Self.loadThrottleUpstreamKbps()
    throttleOnlySelectedHosts = Self.loadThrottleOnlySelectedHosts()
    throttleSelectedHosts = Self.loadThrottleSelectedHosts()
    bindPersistence()
    refreshInternalCAStatus()
    refreshCACertKeychainStatus()
    refreshMacSystemProxyStatus()
    refreshHelperStatus()
    do {
      runtimeCoordinator.onLog = { [weak self] level, message in
        Task { @MainActor [weak self] in
          self?.appendLog(level: level, message: message)
        }
      }
      try runtimeCoordinator.initializeEngine(listenAddress: listenAddress)
      let runtimeRunning = self.engine?.isProxyRunning() ?? false
      let captureRunning = runtimeRunning ? (self.engine?.isCaptureRunning() ?? false) : false
      self.isRuntimeRunning = runtimeRunning
      self.isCaptureEnabled = captureRunning
      self.lastObservedRuntimeRunning = runtimeRunning
      self.lastObservedCaptureRunning = captureRunning
      self.statusText = runtimeRunning
        ? Self.runtimeStatusSummary(proxyRunning: runtimeRunning, captureRunning: captureRunning)
        : Self.proxyReadyStatusSummary
    } catch {
      self.statusText = "Init failed: \(error.localizedDescription)"
    }
    startRuntimeConfigSync()
    startRuntimeStatusSync()
    rebuildFilteredLogs()
  }

  deinit {
    logFlushTask?.cancel()
    listenAddressApplyTask?.cancel()
    lanClientAllowlistApplyTask?.cancel()
    inspectBodiesApplyTask?.cancel()
    throttleApplyTask?.cancel()
    runtimeRulesSyncTask?.cancel()
    runtimeConfigSyncTask?.cancel()
    runtimeStatusSyncTask?.cancel()
    runtimeBootstrapTask?.cancel()
  }

  var selectedLog: ProxyLogEntry? {
    logStore.selectedLog(id: selectedLogID)
  }

  var groupedByDomain: [DomainGroup] {
    let grouped = Dictionary(grouping: filteredLogs) { entry in
      domainName(from: entry.url)
    }
    return grouped
      .map { domain, entries in
        DomainGroup(
          domain: domain,
          count: entries.count,
          hasMacOS: entries.contains { $0.clientPlatform == .macOS },
          hasMobile: entries.contains { $0.clientPlatform == .mobile }
        )
      }
      .sorted {
        if $0.count == $1.count {
          return $0.domain < $1.domain
        }
        return $0.count > $1.count
      }
  }

  func filteredLogs(forDomain domain: String?) -> [ProxyLogEntry] {
    guard let domain else { return filteredLogs }
    return filteredLogs.filter { domainName(from: $0.url) == domain }
  }

  var parsedListen: (host: String, port: UInt16) {
    parseListenAddress()
  }

  var mobileProxyEndpoint: String? {
    let listen = parsedListen
    if isLoopbackHost(listen.host) {
      return nil
    }
    if isAllInterfacesHost(listen.host) {
      guard let lanIP = preferredLANIPv4Address() else {
        return nil
      }
      return "\(lanIP):\(listen.port)"
    }
    return "\(listen.host):\(listen.port)"
  }

  var mobileListenGuide: String {
    let listen = parsedListen
    if isLoopbackHost(listen.host) {
      return "Enable Allow LAN connections to use this Mac from iOS/Android."
    }
    if isAllInterfacesHost(listen.host) {
      if preferredLANIPv4Address() == nil {
        return "No LAN IPv4 found. Check Wi-Fi/LAN connection."
      }
      return "Use the Mac LAN IP below as proxy server on phone."
    }
    return "Phone proxy server should match this host:port."
  }

  func addLANClientAllowlistIP(_ rawIP: String) {
    guard let normalized = Self.normalizedIPAddress(rawIP) else {
      statusText = "Invalid IP address. Enter IPv4 or IPv6."
      return
    }
    if lanClientAllowlist.contains(normalized) {
      statusText = "IP already allowed: \(normalized)"
      return
    }
    lanClientAllowlist.append(normalized)
    dismissedLANAccessIPs.remove(normalized)
    statusText = "Allowed LAN IP added: \(normalized)"
  }

  func removeLANClientAllowlistIP(_ ip: String) {
    let normalized = ip.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    let before = lanClientAllowlist.count
    lanClientAllowlist.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
    if lanClientAllowlist.count != before {
      statusText = "Allowed LAN IP removed: \(normalized)"
    }
  }

  func approvePendingLANAccessRequest() {
    guard let ip = pendingLANAccessRequestIP else { return }
    pendingLANAccessRequestIP = nil
    dismissedLANAccessIPs.remove(ip)
    if lanClientAllowlist.contains(ip) {
      statusText = "LAN device already allowed: \(ip)"
    } else {
      lanClientAllowlist.append(ip)
      statusText = "LAN access allowed: \(ip)"
    }
    advancePendingLANAccessPromptIfNeeded()
  }

  func denyPendingLANAccessRequest() {
    guard let ip = pendingLANAccessRequestIP else { return }
    pendingLANAccessRequestIP = nil
    dismissedLANAccessIPs.insert(ip)
    statusText = "LAN access denied: \(ip)"
    advancePendingLANAccessPromptIfNeeded()
  }

  func dismissPendingLANAccessRequest() {
    guard let ip = pendingLANAccessRequestIP else { return }
    pendingLANAccessRequestIP = nil
    dismissedLANAccessIPs.insert(ip)
    advancePendingLANAccessPromptIfNeeded()
  }

  func startCapture() {
    guard let engine else {
      statusText = "Engine not initialized"
      return
    }

    if engine.isProxyRunning() && isCaptureEnabled {
      isRuntimeRunning = true
      isCaptureEnabled = true
      statusText = Self.runtimeStatusSummary(proxyRunning: true, captureRunning: true)
      return
    }

    do {
      try transitionProxyRuntime(to: .capture)
      isRuntimeRunning = true
      isCaptureEnabled = true
      statusText = Self.runtimeStatusSummary(proxyRunning: true, captureRunning: true)
    } catch {
      let runtimeStillRunning = self.engine?.isProxyRunning() ?? false
      isRuntimeRunning = runtimeStillRunning
      isCaptureEnabled = runtimeStillRunning ? (self.engine?.isCaptureRunning() ?? false) : false
      let nsError = error as NSError
      if let filePath = nsError.userInfo[NSFilePathErrorKey] as? String {
        statusText = "Start capture failed: \(error.localizedDescription) (\(filePath))"
      } else {
        statusText = "Start capture failed: \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
      }
    }
  }

  func stopCapture() {
    guard engine != nil else {
      statusText = "Engine not initialized"
      return
    }

    do {
      try transitionProxyRuntime(to: .bypass)
      isRuntimeRunning = true
      isCaptureEnabled = false
      statusText = Self.runtimeStatusSummary(proxyRunning: true, captureRunning: false)
    } catch {
      let runtimeStillRunning = engine?.isProxyRunning() ?? false
      isRuntimeRunning = runtimeStillRunning
      if !runtimeStillRunning {
        isCaptureEnabled = false
      } else {
        isCaptureEnabled = engine?.isCaptureRunning() ?? false
      }

      let baseMessage = "Stop capture failed: \(error.localizedDescription)"
      if runtimeStillRunning {
        let captureState = isCaptureEnabled ? "capture still running" : "capture stopped"
        statusText = "\(baseMessage) (proxy still running; \(captureState))"
      } else {
        statusText = baseMessage
        recoverMacSystemProxyAfterRuntimeFailureIfNeeded(statusPrefix: baseMessage)
      }
    }
  }

  func ensureProxyRuntimeReadyInBypassMode() {
    guard runtimeBootstrapTask == nil else { return }
    runtimeBootstrapTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.runtimeBootstrapTask = nil }

      guard let engine else { return }
      if engine.isProxyRunning() {
        self.isRuntimeRunning = true
        self.isCaptureEnabled = engine.isCaptureRunning()
        return
      }

      do {
        try self.transitionProxyRuntime(to: .bypass)
        self.isRuntimeRunning = true
        self.isCaptureEnabled = false
        if Self.isRuntimeStatusSummary(self.statusText) {
          self.statusText = Self.runtimeStatusSummary(proxyRunning: true, captureRunning: false)
        }
      } catch {
        let runtimeStillRunning = self.engine?.isProxyRunning() ?? false
        self.isRuntimeRunning = runtimeStillRunning
        if !runtimeStillRunning {
          self.isCaptureEnabled = false
        } else {
          self.isCaptureEnabled = self.engine?.isCaptureRunning() ?? false
        }
      }
    }
  }

  func shutdownForAppTermination() {
    mcpHttpService.stop()
    guard let engine else { return }

    // Best-effort: clear daemon-side ring buffer so the next app launch starts clean
    // even if daemon shutdown falls back to proxy.stop().
    try? engine.clearDaemonLogs()

    do {
      try engine.shutdownDaemon()
    } catch {
      // Best-effort fallback: at least stop active proxy task if daemon shutdown RPC fails.
      try? engine.stopProxyRuntime()
    }

    isCaptureEnabled = false
    isRuntimeRunning = false
  }

  func clearLogs(showStatus: Bool = true) {
    suppressIncomingLogs = true
    suppressIncomingLogsGeneration &+= 1
    let clearGeneration = suppressIncomingLogsGeneration

    var daemonClearError: Error?
    if let engine {
      do {
        try engine.clearDaemonLogs()
      } catch {
        daemonClearError = error
      }
    }

    logFlushTask?.cancel()
    logFlushTask = nil
    pendingLogEvents.removeAll(keepingCapacity: true)
    pendingClientAppResolutionIDs.removeAll(keepingCapacity: true)
    clientAppResolutionAttempts.removeAll(keepingCapacity: true)
    logs = logStore.clear()
    filteredLogs.removeAll(keepingCapacity: true)
    selectedLogID = nil

    if showStatus {
      if let daemonClearError {
        statusText = "Local logs cleared (daemon clear failed: \(daemonClearError.localizedDescription))"
      } else {
        statusText = "Traffic logs cleared"
      }
    }

    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      guard self.suppressIncomingLogsGeneration == clearGeneration else { return }
      self.suppressIncomingLogs = false
    }
  }

  func replay(entryID: ProxyLogEntry.ID) {
    guard let entry = logStore.selectedLog(id: entryID) ?? logs.first(where: { $0.id == entryID }) else {
      statusText = "Replay failed: selected request no longer exists."
      return
    }
    guard let draft = replayDraft(from: entry) else { return }

    statusText = "Replay started: \(draft.method) \(replayTargetLabel(for: draft.url))"
    Task { [weak self] in
      await self?.performReplay(draft)
    }
  }

  var macSystemProxyTarget: String {
    "127.0.0.1:\(parsedListen.port)"
  }

  func refreshMacSystemProxyStatus(autoEnableIfDisabled: Bool = false) {
    let systemProxyService = self.systemProxyService
    Task {
      do {
        let status = try await Task.detached(priority: .userInitiated) {
          try systemProxyService.readStatus()
        }.value
        applyMacSystemProxyStatus(status)
        if autoEnableIfDisabled && !status.isEnabled {
          enableMacSystemProxy()
        }
      } catch {
        macSystemProxyEnabled = false
        macSystemProxyServiceText = "Unknown"
        macSystemProxyStateText = "Unavailable"
      }
    }
  }

  func enableMacSystemProxy() {
    guard !isApplyingMacSystemProxy else { return }
    let port = Int(parsedListen.port)
    let systemProxyService = self.systemProxyService
    isApplyingMacSystemProxy = true

    Task {
      defer { isApplyingMacSystemProxy = false }
      do {
        let status = try await Task.detached(priority: .userInitiated) {
          try systemProxyService.enable(host: "127.0.0.1", port: port)
        }.value
        applyMacSystemProxyStatus(status)
        statusText = "macOS system proxy enabled"
      } catch {
        statusText = "Enable macOS proxy failed: \(error.localizedDescription)"
        refreshMacSystemProxyStatus()
      }
    }
  }

  func disableMacSystemProxy() {
    guard !isApplyingMacSystemProxy else { return }
    let systemProxyService = self.systemProxyService
    isApplyingMacSystemProxy = true

    Task {
      defer { isApplyingMacSystemProxy = false }
      do {
        let status = try await Task.detached(priority: .userInitiated) {
          try systemProxyService.disable()
        }.value
        applyMacSystemProxyStatus(status)
        statusText = "macOS system proxy disabled"
      } catch {
        statusText = "Disable macOS proxy failed: \(error.localizedDescription)"
        refreshMacSystemProxyStatus()
      }
    }
  }

  private func recoverMacSystemProxyAfterRuntimeFailureIfNeeded(statusPrefix: String) {
    guard macSystemProxyEnabled else { return }
    guard !isApplyingMacSystemProxy else { return }

    let systemProxyService = self.systemProxyService
    isApplyingMacSystemProxy = true

    Task {
      defer { isApplyingMacSystemProxy = false }
      do {
        let status = try await Task.detached(priority: .userInitiated) {
          try systemProxyService.disable()
        }.value
        applyMacSystemProxyStatus(status)
        statusText = "\(statusPrefix) (disabled macOS system proxy for recovery)"
      } catch {
        statusText = "\(statusPrefix) (failed to disable macOS system proxy: \(error.localizedDescription))"
        refreshMacSystemProxyStatus()
      }
    }
  }

  func enableTransparentProxy() {
    guard !isApplyingTransparentProxy else { return }
    isApplyingTransparentProxy = true
    let pfService = self.pfService
    let transparentProxyPort = self.transparentProxyPort
    let certPathToInstall = caCertInstalledInKeychain ? nil : (caCertPath.isEmpty ? nil : caCertPath)

    Task {
      defer { isApplyingTransparentProxy = false }
      do {
        let reconfigureContext = try prepareRuntimeForReconfigure()

        guard let engine else {
          transparentProxyEnabled = false
          statusText = "Engine not initialized"
          return
        }

        try engine.setTransparentEnabled(true)
        try engine.setTransparentPort(transparentProxyPort)

        try await pfService.enable(proxyPort: Int(transparentProxyPort), certInstallPath: certPathToInstall)

        if certPathToInstall != nil {
          caCertInstalledInKeychain = true
        }

        try restoreRuntimeAfterReconfigureIfNeeded(reconfigureContext)

        transparentProxyEnabled = true
        transparentProxyStateText = "ON (port \(transparentProxyPort))"
        statusText = "Transparent proxy enabled"
      } catch {
        transparentProxyEnabled = false
        transparentProxyStateText = "OFF"
        statusText = "Enable transparent proxy failed: \(error.localizedDescription)"
      }
    }
  }

  func disableTransparentProxy() {
    guard !isApplyingTransparentProxy else { return }
    isApplyingTransparentProxy = true
    let pfService = self.pfService

    Task {
      defer { isApplyingTransparentProxy = false }
      do {
        try await pfService.disable()

        if engine != nil {
          let reconfigureContext = try prepareRuntimeForReconfigure()
          guard let activeEngine = self.engine else {
            throw ProxyViewModelError.invalidValue("Engine not initialized")
          }
          try activeEngine.setTransparentEnabled(false)
          try restoreRuntimeAfterReconfigureIfNeeded(reconfigureContext)
        }

        transparentProxyEnabled = false
        transparentProxyStateText = "OFF"
        statusText = "Transparent proxy disabled"
      } catch {
        statusText = "Disable transparent proxy failed: \(error.localizedDescription)"
      }
    }
  }

  func installCACertToKeychain() {
    guard !isInstallingCACert else { return }
    do {
      if caCertPath.isEmpty {
        let urls = try internalCAURLs()
        let fm = FileManager.default
        if !fm.fileExists(atPath: urls.cert.path) || !fm.fileExists(atPath: urls.key.path) {
          try RustProxyEngine.generateCA(
            commonName: internalCACommonName,
            days: internalCADays,
            certPath: urls.cert.path,
            keyPath: urls.key.path
          )
        }
        refreshInternalCAStatus()
      }
    } catch {
      statusText = "Prepare CA cert failed: \(error.localizedDescription)"
      return
    }

    guard !caCertPath.isEmpty else {
      statusText = "CA certificate path unavailable"
      return
    }
    isInstallingCACert = true
    let certPath = caCertPath
    let caCertService = self.caCertService

    Task {
      defer { isInstallingCACert = false }
      do {
        try await caCertService.installToSystemKeychain(certPath: certPath)
        caCertInstalledInKeychain = true
        statusText = "CA certificate installed to System Keychain"
      } catch {
        statusText = "Install CA cert failed: \(error.localizedDescription)"
      }
    }
  }

  func removeCACertFromKeychain() {
    guard !isInstallingCACert else { return }
    isInstallingCACert = true
    let commonName = internalCACommonName
    let caCertService = self.caCertService

    Task {
      defer { isInstallingCACert = false }
      do {
        try await caCertService.removeFromSystemKeychain(commonName: commonName)
        caCertInstalledInKeychain = false
        statusText = "CA certificate removed from System Keychain"
      } catch {
        statusText = "Remove CA cert failed: \(error.localizedDescription)"
      }
    }
  }

  func refreshCACertKeychainStatus() {
    let commonName = internalCACommonName
    let caCertService = self.caCertService
    Task {
      let installed = await caCertService.isInstalledInSystemKeychain(commonName: commonName)
      caCertInstalledInKeychain = installed
    }
  }

  func refreshHelperStatus() {
    let fileInstalled = HelperInstaller.isInstalled()
    helperInstalled = fileInstalled
    guard fileInstalled else { return }

    let helperClient = HelperClient()
    Task {
      let available = await helperClient.isAvailable()
      helperInstalled = available
    }
  }

  func installHelper() {
    guard !isInstallingHelper else { return }
    isInstallingHelper = true

    Task {
      defer { isInstallingHelper = false }
      do {
        try await Task.detached(priority: .userInitiated) {
          try HelperInstaller.install()
        }.value

        let helperClient = HelperClient()
        var available = false
        for _ in 0..<5 {
          available = await helperClient.isAvailable()
          if available {
            break
          }
          try? await Task.sleep(nanoseconds: 200_000_000)
        }

        helperInstalled = available
        statusText = available
          ? "Helper daemon installed"
          : "Helper installed but daemon unavailable. Using admin prompt fallback."
      } catch {
        statusText = "Helper install failed: \(error.localizedDescription)"
      }
    }
  }

  func uninstallHelper() {
    guard !isInstallingHelper else { return }
    isInstallingHelper = true

    Task {
      defer { isInstallingHelper = false }
      do {
        try await Task.detached(priority: .userInitiated) {
          try HelperInstaller.uninstall()
        }.value
        helperInstalled = false
        statusText = "Helper daemon uninstalled"
      } catch {
        statusText = "Helper uninstall failed: \(error.localizedDescription)"
      }
    }
  }

  func regenerateInternalCA() {
    guard !isCaptureEnabled else {
      statusText = "Stop proxy before regenerating CA"
      return
    }

    do {
      let urls = try internalCAURLs()
      let fm = FileManager.default
      if fm.fileExists(atPath: urls.cert.path) {
        try fm.removeItem(at: urls.cert)
      }
      if fm.fileExists(atPath: urls.key.path) {
        try fm.removeItem(at: urls.key)
      }
      try RustProxyEngine.generateCA(
        commonName: internalCACommonName,
        days: internalCADays,
        certPath: urls.cert.path,
        keyPath: urls.key.path
      )
      refreshInternalCAStatus()
      statusText = "Internal CA regenerated. Reinstall certificate on devices."
    } catch {
      statusText = "CA regenerate failed: \(error.localizedDescription)"
    }
  }

  func addMapLocalRule() {
    mapLocalRules.append(MapLocalRuleInput())
  }

  func stageMapLocalRule(from entry: ProxyLogEntry) {
    let matcher = defaultMapLocalMatcher(from: entry.url)
    let statusCode: String
    if let raw = entry.statusCode, let code = UInt16(raw), (100...599).contains(code) {
      statusCode = String(code)
    } else {
      statusCode = "200"
    }

    stagedMapLocalRule = MapLocalRuleInput(
      isEnabled: true,
      matcher: matcher,
      sourceType: .file,
      sourceValue: "",
      statusCode: statusCode,
      contentType: ""
    )
    statusText = "Map Local draft added. Choose a file and save changes."
  }

  func consumeStagedMapLocalRule() -> MapLocalRuleInput? {
    let rule = stagedMapLocalRule
    stagedMapLocalRule = nil
    return rule
  }

  func stageMapRemoteRule(from entry: ProxyLogEntry) {
    let matcher = defaultMapLocalMatcher(from: entry.url)
    stagedMapRemoteRule = MapRemoteRuleInput(
      isEnabled: true,
      matcher: matcher,
      destinationURL: ""
    )
    statusText = "Map Remote draft added. Enter destination URL and save changes."
  }

  func consumeStagedMapRemoteRule() -> MapRemoteRuleInput? {
    let rule = stagedMapRemoteRule
    stagedMapRemoteRule = nil
    return rule
  }

  func stageAllowRule(from entry: ProxyLogEntry) {
    guard let matcher = defaultAllowMatcher(from: entry.url) else {
      statusText = "Cannot derive allowlist matcher from selected request."
      return
    }
    stagedAllowRule = AllowRuleInput(matcher: matcher)
    statusText = "Allowlist draft added. Review and save changes."
  }

  func consumeStagedAllowRule() -> AllowRuleInput? {
    let rule = stagedAllowRule
    stagedAllowRule = nil
    return rule
  }

  func stageStatusRewriteRule(from entry: ProxyLogEntry) {
    let matcher = defaultMapLocalMatcher(from: entry.url)
    let fromStatusCode: String
    if let raw = entry.statusCode, let code = UInt16(raw), (100...599).contains(code) {
      fromStatusCode = String(code)
    } else {
      fromStatusCode = ""
    }

    stagedStatusRewriteRule = StatusRewriteRuleInput(
      isEnabled: true,
      matcher: matcher,
      fromStatusCode: fromStatusCode,
      toStatusCode: "200"
    )
    statusText = "Status Rewrite draft added. Review and save changes."
  }

  func consumeStagedStatusRewriteRule() -> StatusRewriteRuleInput? {
    let rule = stagedStatusRewriteRule
    stagedStatusRewriteRule = nil
    return rule
  }

  func addAllowRule() {
    allowRules.append(AllowRuleInput())
  }

  func removeAllowRule(_ id: UUID) {
    allowRules.removeAll { $0.id == id }
  }

  func removeMapLocalRule(_ id: UUID) {
    mapLocalRules.removeAll { $0.id == id }
  }

  func addStatusRewriteRule() {
    statusRewriteRules.append(StatusRewriteRuleInput())
  }

  func removeStatusRewriteRule(_ id: UUID) {
    statusRewriteRules.removeAll { $0.id == id }
  }

  func saveRules(
    allowRules: [AllowRuleInput],
    mapLocalRules: [MapLocalRuleInput],
    mapRemoteRules: [MapRemoteRuleInput],
    statusRewriteRules: [StatusRewriteRuleInput]
  ) {
    let mergedAllowRules = mergedAllowRulesForMappedRules(
      allowRules: allowRules,
      mapLocalRules: mapLocalRules,
      mapRemoteRules: mapRemoteRules
    )

    do {
      try ruleManager.validateRules(
        allowRules: mergedAllowRules,
        mapLocalRules: mapLocalRules,
        mapRemoteRules: mapRemoteRules,
        statusRewriteRules: statusRewriteRules
      )
    } catch {
      statusText = "Save failed: \(error.localizedDescription)"
      return
    }

    self.allowRules = mergedAllowRules
    self.mapLocalRules = mapLocalRules
    self.mapRemoteRules = mapRemoteRules
    self.statusRewriteRules = statusRewriteRules
    // Persist immediately so values survive app/tab transitions even if app exits quickly.
    persistAllowRules()
    persistMapLocalRules()
    persistMapRemoteRules()
    persistStatusRewriteRules()

    do {
      let runtimeWasRunning = try applyRulesToEngineAfterSave()
      statusText = runtimeWasRunning ? "Rules saved and applied" : "Rules saved"
    } catch {
      let runtimeStillRunning = engine?.isProxyRunning() ?? false
      isRuntimeRunning = runtimeStillRunning
      if !runtimeStillRunning {
        isCaptureEnabled = false
      } else {
        isCaptureEnabled = engine?.isCaptureRunning() ?? false
      }
      statusText = "Save failed: \(error.localizedDescription)"
    }
  }

  private func applyRulesToEngineAfterSave() throws -> Bool {
    guard let engine else {
      return false
    }

    let interceptWasEnabled = isCaptureEnabled
    let runtimeIsActive = engine.isProxyRunning()
    if runtimeIsActive && !interceptWasEnabled {
      // Bypass mode keeps the proxy server alive with runtime rules intentionally cleared.
      // Persist the UI rules but defer applying them until intercept mode is enabled again.
      return false
    }

    if interceptWasEnabled {
      try stopProxyRuntimeForReconfigure()
    }

    if interceptWasEnabled {
      try transitionProxyRuntime(to: .capture)
    } else {
      guard let activeEngine = self.engine else {
        throw ProxyViewModelError.invalidValue("Engine not initialized")
      }
      try syncRules(to: activeEngine)
    }

    isCaptureEnabled = interceptWasEnabled
    isRuntimeRunning = engine.isProxyRunning()
    return interceptWasEnabled
  }

  private func applyMacSystemProxyStatus(_ status: MacSystemProxyStatus) {
    macSystemProxyEnabled = status.isEnabled
    macSystemProxyServiceText = "\(status.networkService) (\(status.interfaceName))"
    macSystemProxyStateText = status.isEnabled ? "ON • \(status.activeEndpoint)" : "OFF"
  }

  private func syncRules(to engine: any ProxyEngineControlling) throws {
    try ruleManager.syncRules(
      to: engine,
      allowRules: allowRules,
      mapLocalRules: mapLocalRules,
      mapRemoteRules: mapRemoteRules,
      statusRewriteRules: statusRewriteRules
    )
  }

  private func stopProxyRuntimeForReconfigure() throws {
    try runtimeCoordinator.stopRuntimeForReconfigure(listenAddress: listenAddress)
  }

  private func prepareRuntimeForReconfigure() throws -> ProxyRuntimeCoordinator.ReconfigureContext {
    try runtimeCoordinator.prepareForReconfigure(
      captureEnabled: isCaptureEnabled,
      listenAddress: listenAddress
    )
  }

  private func restoreRuntimeAfterReconfigureIfNeeded(
    _ context: ProxyRuntimeCoordinator.ReconfigureContext
  ) throws {
    try runtimeCoordinator.restoreAfterReconfigureIfNeeded(
      context,
      listenAddress: listenAddress,
      configure: { [self] engine, mode in
        try applyRuntimeModeConfiguration(to: engine, mode: mode)
      }
    )
    isCaptureEnabled = context.captureWasEnabled
    isRuntimeRunning = context.runtimeWasRunning
  }

  private func applyRuntimeModeConfiguration(
    to engine: any ProxyEngineControlling,
    mode: ProxyRuntimeCoordinator.Mode
  ) throws {
    try applyLANAccessConfig(to: engine)
    if transparentProxyEnabled {
      try engine.setTransparentEnabled(true)
      try engine.setTransparentPort(transparentProxyPort)
    }

    if mode.capturesTraffic {
      try engine.setInspectEnabled(inspectBodies)
      try applyThrottleConfig(to: engine)
      try syncRules(to: engine)
      try ensureInternalCALoaded(engine: engine)
    } else {
      try engine.setInspectEnabled(false)
      try applyBypassThrottleConfig(to: engine)
      try engine.clearRules()
    }

  }

  private func transitionProxyRuntime(to mode: ProxyRuntimeCoordinator.Mode) throws {
    try runtimeCoordinator.transitionRuntime(
      to: mode,
      listenAddress: listenAddress,
      configure: { [self] engine, mode in
        try applyRuntimeModeConfiguration(to: engine, mode: mode)
      }
    )
  }

  private func applyBypassThrottleConfig(to engine: any ProxyEngineControlling) throws {
    try engine.setThrottleEnabled(false)
    try engine.setThrottleLatencyMs(0)
    try engine.setThrottleDownstreamBytesPerSecond(0)
    try engine.setThrottleUpstreamBytesPerSecond(0)
    try engine.setThrottleOnlySelectedHosts(false)
    try engine.clearThrottleSelectedHosts()
  }

  func startRulesRuntimeSync() {
    guard runtimeRulesSyncTask == nil else { return }
    runtimeRulesSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runRulesRuntimeSyncLoop()
    }
  }

  func stopRulesRuntimeSync() {
    runtimeRulesSyncTask?.cancel()
    runtimeRulesSyncTask = nil
  }

  private func startRuntimeConfigSync() {
    guard runtimeConfigSyncTask == nil else { return }
    runtimeConfigSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runRuntimeConfigSyncLoop()
    }
  }

  private func runRuntimeConfigSyncLoop() async {
    refreshRuntimeConfigFromDaemonIfChanged()
    if runtimeRulesSyncTask == nil {
      refreshRulesFromRuntimeIfChanged()
    }

    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: runtimeConfigSyncIntervalNanoseconds)
      } catch {
        break
      }
      if Task.isCancelled {
        break
      }
      refreshRuntimeConfigFromDaemonIfChanged()
      if runtimeRulesSyncTask == nil {
        refreshRulesFromRuntimeIfChanged()
      }
    }
  }

  private func startRuntimeStatusSync() {
    guard runtimeStatusSyncTask == nil else { return }
    runtimeStatusSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runRuntimeStatusSyncLoop()
    }
  }

  private func runRuntimeStatusSyncLoop() async {
    refreshRuntimeStatusFromDaemon()

    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: runtimeStatusSyncIntervalNanoseconds)
      } catch {
        break
      }
      if Task.isCancelled {
        break
      }
      refreshRuntimeStatusFromDaemon()
    }
  }

  private func refreshRuntimeStatusFromDaemon() {
    guard let engine else {
      lastObservedRuntimeRunning = nil
      lastObservedCaptureRunning = nil
      lastObservedRuntimeRulesDump = nil
      lastObservedRuntimeConfigDump = nil
      return
    }

    let runtimeRunning = engine.isProxyRunning()
    let captureRunning = runtimeRunning ? engine.isCaptureRunning() : false
    let previousRuntime = lastObservedRuntimeRunning
    let previousCapture = lastObservedCaptureRunning
    lastObservedRuntimeRunning = runtimeRunning
    lastObservedCaptureRunning = captureRunning

    guard previousRuntime != runtimeRunning || previousCapture != captureRunning else { return }

    isRuntimeRunning = runtimeRunning
    isCaptureEnabled = captureRunning

    if Self.isRuntimeStatusSummary(statusText) {
      statusText = runtimeRunning
        ? Self.runtimeStatusSummary(proxyRunning: runtimeRunning, captureRunning: captureRunning)
        : Self.proxyStoppedStatusSummary
    }

    // External control (MCP/CLI) can toggle capture/rules without UI actions.
    // Pull daemon snapshots immediately when status changes so the UI catches up faster.
    if let cachedConfig = lastObservedRuntimeConfigDump {
      applyRuntimeConfigFromDaemon(cachedConfig)
    }
    refreshRuntimeConfigFromDaemonIfChanged()
    refreshRulesFromRuntimeIfChanged()
  }

  private func refreshRuntimeConfigFromDaemonIfChanged() {
    guard let engine else { return }

    let runtimeConfig: RuntimeEngineConfigDump
    do {
      runtimeConfig = try engine.dumpConfig()
    } catch {
      return
    }

    guard lastObservedRuntimeConfigDump != runtimeConfig else { return }
    lastObservedRuntimeConfigDump = runtimeConfig
    applyRuntimeConfigFromDaemon(runtimeConfig)
  }

  private func applyRuntimeConfigFromDaemon(_ config: RuntimeEngineConfigDump) {
    withExternalRuntimeConfigApplySuppressed {
      if let listen = parseListenAddressComponents(from: config.listenAddress) {
        let lanMode = !isLoopbackHost(listen.host) || config.clientAllowlist.enabled
        allowLANConnections = lanMode
      } else {
        allowLANConnections = config.clientAllowlist.enabled
      }

      lanClientAllowlist = config.clientAllowlist.ips

      if shouldSyncCaptureModePreferencesFromDaemon(config) {
        inspectBodies = config.inspect.enabled
        throttleEnabled = config.throttle.enabled
        throttleLatencyMs = normalizedKbpsOrMsInt(from: config.throttle.latencyMs)
        throttleDownstreamKbps = kbpsInt(fromBytesPerSecond: config.throttle.downstreamBytesPerSecond)
        throttleUpstreamKbps = kbpsInt(fromBytesPerSecond: config.throttle.upstreamBytesPerSecond)
        throttleOnlySelectedHosts = config.throttle.onlySelectedHosts
        throttleSelectedHosts = config.throttle.selectedHosts
      }
    }

    if !isApplyingTransparentProxy {
      transparentProxyEnabled = config.transparent.enabled
      if config.transparent.enabled {
        transparentProxyStateText = "ON (port \(config.transparent.listenPort))"
      } else {
        transparentProxyStateText = "OFF"
      }
    }
  }

  private func withExternalRuntimeConfigApplySuppressed(_ body: () -> Void) {
    let previous = suppressExternalRuntimeConfigApply
    suppressExternalRuntimeConfigApply = true
    body()
    suppressExternalRuntimeConfigApply = previous
  }

  private func shouldSyncCaptureModePreferencesFromDaemon(_ config: RuntimeEngineConfigDump) -> Bool {
    isCaptureEnabled || !config.running
  }

  private func runRulesRuntimeSyncLoop() async {
    refreshRulesFromRuntimeIfChanged()

    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: runtimeRulesSyncIntervalNanoseconds)
      } catch {
        break
      }
      if Task.isCancelled {
        break
      }
      refreshRulesFromRuntimeIfChanged()
    }
  }

  private func refreshRulesFromRuntimeIfChanged() {
    guard let engine else { return }

    let runtimeRules: RuntimeRulesDump
    do {
      runtimeRules = try engine.dumpRules()
    } catch {
      return
    }

    let runtimeRulesHasEntries =
      !runtimeRules.allowlist.isEmpty
      || !runtimeRules.mapLocal.isEmpty
      || !runtimeRules.mapRemote.isEmpty
      || !runtimeRules.statusRewrite.isEmpty

    if !isCaptureEnabled && isRuntimeRunning && !runtimeRulesHasEntries {
      // App-managed bypass mode often clears runtime rules intentionally.
      // Keep the UI's saved capture rules unless an external agent has written non-empty runtime rules.
      lastObservedRuntimeRulesDump = runtimeRules
      return
    }

    guard lastObservedRuntimeRulesDump != runtimeRules else { return }
    lastObservedRuntimeRulesDump = runtimeRules

    let runtimeAllow = runtimeRules.allowlist
    let runtimeMapLocal = canonicalMapLocalRules(from: runtimeRules.mapLocal)
    let runtimeMapRemote = canonicalMapRemoteRules(from: runtimeRules.mapRemote)
    let runtimeStatusRewrite = canonicalStatusRewriteRules(from: runtimeRules.statusRewrite)

    let currentAllow = ruleManager.normalizedAllowMatchers(from: allowRules)
    let currentMapLocal = canonicalEnabledMapLocalRules(from: mapLocalRules)
    let currentMapRemote = canonicalEnabledMapRemoteRules(from: mapRemoteRules)
    let currentStatusRewrite = canonicalEnabledStatusRewriteRules(from: statusRewriteRules)

    guard currentAllow != runtimeAllow
      || currentMapLocal != runtimeMapLocal
      || currentMapRemote != runtimeMapRemote
      || currentStatusRewrite != runtimeStatusRewrite
    else {
      return
    }

    let disabledMapLocalRules = mapLocalRules.filter { !$0.isEnabled }
    let disabledMapRemoteRules = mapRemoteRules.filter { !$0.isEnabled }
    let disabledStatusRewriteRules = statusRewriteRules.filter { !$0.isEnabled }

    allowRules = runtimeAllow.map { AllowRuleInput(matcher: $0) }
    mapLocalRules = mapLocalRuleInputs(from: runtimeRules.mapLocal) + disabledMapLocalRules
    mapRemoteRules = mapRemoteRuleInputs(from: runtimeRules.mapRemote) + disabledMapRemoteRules
    statusRewriteRules =
      statusRewriteRuleInputs(from: runtimeRules.statusRewrite) + disabledStatusRewriteRules
  }

  private func applyThrottleConfig(to engine: any ProxyEngineControlling) throws {
    let enabled = throttleEnabled
    let latencyMs = UInt64(Self.normalizedNonNegativeInt(throttleLatencyMs))
    let downstreamKbps = UInt64(Self.normalizedNonNegativeInt(throttleDownstreamKbps))
    let upstreamKbps = UInt64(Self.normalizedNonNegativeInt(throttleUpstreamKbps))
    let downstreamMultiply = downstreamKbps.multipliedReportingOverflow(by: 1024)
    let upstreamMultiply = upstreamKbps.multipliedReportingOverflow(by: 1024)
    let downstreamBytesPerSecond = downstreamMultiply.overflow
      ? UInt64.max
      : downstreamMultiply.partialValue
    let upstreamBytesPerSecond = upstreamMultiply.overflow ? UInt64.max : upstreamMultiply.partialValue

    try engine.setThrottleEnabled(enabled)
    try engine.setThrottleLatencyMs(latencyMs)
    try engine.setThrottleDownstreamBytesPerSecond(downstreamBytesPerSecond)
    try engine.setThrottleUpstreamBytesPerSecond(upstreamBytesPerSecond)
    try engine.setThrottleOnlySelectedHosts(throttleOnlySelectedHosts)
    try engine.clearThrottleSelectedHosts()
    for matcher in throttleSelectedHosts {
      try engine.addThrottleSelectedHost(matcher)
    }
  }

  private func applyLANAccessConfig(to engine: any ProxyEngineControlling) throws {
    try engine.setClientAllowlistEnabled(allowLANConnections)
    try engine.clearClientAllowlist()
    for ip in lanClientAllowlist {
      try engine.addClientAllowlistIP(ip)
    }
  }

  private func ensureInternalCALoaded(engine: any ProxyEngineControlling) throws {
    let urls = try internalCAURLs()
    let fm = FileManager.default
    let certExists = fm.fileExists(atPath: urls.cert.path)
    let keyExists = fm.fileExists(atPath: urls.key.path)

    if !certExists || !keyExists {
      try RustProxyEngine.generateCA(
        commonName: internalCACommonName,
        days: internalCADays,
        certPath: urls.cert.path,
        keyPath: urls.key.path
      )
    }

    do {
      try engine.loadCA(certPath: urls.cert.path, keyPath: urls.key.path)
    } catch {
      // If stored files are corrupted, regenerate once and retry.
      try RustProxyEngine.generateCA(
        commonName: internalCACommonName,
        days: internalCADays,
        certPath: urls.cert.path,
        keyPath: urls.key.path
      )
      try engine.loadCA(certPath: urls.cert.path, keyPath: urls.key.path)
    }
    refreshInternalCAStatus()
  }

  private func refreshInternalCAStatus() {
    guard let urls = internalCAURLsIfAvailable() else {
      caCertPath = ""
      caStatusText = "Application Support path unavailable"
      return
    }

    caCertPath = urls.cert.path
    let fm = FileManager.default
    if fm.fileExists(atPath: urls.cert.path), fm.fileExists(atPath: urls.key.path) {
      caStatusText = "Internal CA ready"
    } else {
      caStatusText = "Internal CA will be generated on Start"
    }
  }

  private func replayDraft(from entry: ProxyLogEntry) -> ReplayRequestDraft? {
    guard let method = normalizedReplayMethod(from: entry.method) else {
      statusText = "Replay failed: unsupported method (\(entry.method))."
      return nil
    }
    guard
      let url = URL(string: entry.url),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      statusText = "Replay failed: invalid URL."
      return nil
    }

    let headers = replayHeaders(from: entry.requestHeaders)
    let body = replayBody(from: entry.requestBodyPreview)
    return ReplayRequestDraft(
      method: method,
      url: url,
      headers: headers.headers,
      bodyData: body.data,
      redactedHeaderCount: headers.redactedCount,
      omittedBinaryBody: body.omittedBinaryBody
    )
  }

  private func normalizedReplayMethod(from raw: String) -> String? {
    let method = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !method.isEmpty, method != "CONNECT" else { return nil }
    guard
      method.unicodeScalars.allSatisfy({
        Self.replayMethodTokenCharacters.contains($0)
      })
    else {
      return nil
    }
    return method
  }

  private func replayHeaders(from raw: String?) -> (headers: [ReplayHeader], redactedCount: Int) {
    guard let raw else { return ([], 0) }
    var headers: [ReplayHeader] = []
    var redactedCount = 0

    for rawLine in raw.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { continue }
      let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }

      let valueStart = line.index(after: separator)
      let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
      if Self.replayExcludedHeaders.contains(name.lowercased()) {
        continue
      }
      if value.caseInsensitiveCompare("<redacted>") == .orderedSame {
        redactedCount += 1
        continue
      }

      headers.append(ReplayHeader(name: String(name), value: String(value)))
    }

    return (headers, redactedCount)
  }

  private func replayBody(from raw: String?) -> (data: Data?, omittedBinaryBody: Bool) {
    guard let raw, !raw.isEmpty else { return (nil, false) }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (nil, false) }
    if trimmed.lowercased().hasPrefix("<binary ") {
      return (nil, true)
    }
    return (raw.data(using: .utf8), false)
  }

  private func performReplay(_ draft: ReplayRequestDraft) async {
    let noteSuffix = replayNoteSuffix(for: draft)

    if let localProxy = replayLocalProxyEndpoint(for: draft.url) {
      do {
        let response = try await sendReplay(
          draft,
          proxyHost: localProxy.host,
          proxyPort: localProxy.port
        )
        statusText =
          "Replay sent via local proxy (\(response.statusCode))\(noteSuffix)"
        return
      } catch {
        let proxyError = error
        do {
          let response = try await sendReplay(draft, proxyHost: nil, proxyPort: nil)
          statusText =
            "Replay sent directly (\(response.statusCode), proxy fallback)\(noteSuffix)"
          return
        } catch {
          statusText =
            "Replay failed: \(error.localizedDescription) (proxy: \(proxyError.localizedDescription))"
          return
        }
      }
    }

    do {
      let response = try await sendReplay(draft, proxyHost: nil, proxyPort: nil)
      statusText = "Replay sent directly (\(response.statusCode))\(noteSuffix)"
    } catch {
      statusText = "Replay failed: \(error.localizedDescription)"
    }
  }

  private func replayLocalProxyEndpoint(for url: URL) -> (host: String, port: Int)? {
    guard isCaptureEnabled else { return nil }
    let listen = parsedListen
    let normalizedHost = normalizedReplayProxyHost(from: listen.host)
    let port = Int(listen.port)
    guard !normalizedHost.isEmpty else { return nil }

    // Avoid routing replay of proxy's own endpoint back into itself.
    if
      let targetHost = url.host,
      isLoopbackHost(targetHost.lowercased()),
      (url.port ?? defaultPort(for: url)) == port
    {
      return nil
    }
    if
      let targetHost = url.host,
      targetHost.caseInsensitiveCompare(normalizedHost) == .orderedSame,
      (url.port ?? defaultPort(for: url)) == port
    {
      return nil
    }

    return (host: normalizedHost, port: port)
  }

  private func normalizedReplayProxyHost(from host: String) -> String {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if isAllInterfacesHost(trimmedHost) || isLoopbackHost(trimmedHost) {
      return "127.0.0.1"
    }
    if trimmedHost.hasPrefix("["),
      trimmedHost.hasSuffix("]"),
      trimmedHost.count > 2
    {
      return String(trimmedHost.dropFirst().dropLast())
    }
    return trimmedHost
  }

  private func defaultPort(for url: URL) -> Int {
    let scheme = url.scheme?.lowercased() ?? ""
    return scheme == "https" ? 443 : 80
  }

  private func sendReplay(
    _ draft: ReplayRequestDraft,
    proxyHost: String?,
    proxyPort: Int?
  ) async throws -> HTTPURLResponse {
    var request = URLRequest(url: draft.url)
    request.httpMethod = draft.method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 60
    request.httpBody = draft.bodyData

    for header in draft.headers {
      request.addValue(header.value, forHTTPHeaderField: header.name)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 90

    if let proxyHost, let proxyPort {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: proxyHost,
        kCFNetworkProxiesHTTPPort as String: proxyPort,
        kCFNetworkProxiesHTTPSEnable as String: true,
        kCFNetworkProxiesHTTPSProxy as String: proxyHost,
        kCFNetworkProxiesHTTPSPort as String: proxyPort
      ]
    } else {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: false,
        kCFNetworkProxiesHTTPSEnable as String: false
      ]
    }

    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProxyViewModelError.invalidValue("Replay received non-HTTP response")
    }
    return httpResponse
  }

  private func replayNoteSuffix(for draft: ReplayRequestDraft) -> String {
    var notes: [String] = []
    if draft.redactedHeaderCount > 0 {
      notes.append("\(draft.redactedHeaderCount) redacted header(s) skipped")
    }
    if draft.omittedBinaryBody {
      notes.append("binary body skipped")
    }
    guard !notes.isEmpty else { return "" }
    return " (\(notes.joined(separator: ", ")))"
  }

  private func replayTargetLabel(for url: URL) -> String {
    let host = url.host ?? url.absoluteString
    let path = url.path.isEmpty ? "/" : url.path
    let target = "\(host)\(path)"
    if target.count > 80 {
      return String(target.prefix(77)) + "..."
    }
    return target
  }

  private func internalCAURLsIfAvailable() -> (cert: URL, key: URL)? {
    guard
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      return nil
    }
    let dir =
      appSupport
      .appendingPathComponent("CrabProxyMacApp", isDirectory: true)
      .appendingPathComponent("ca", isDirectory: true)
    return (
      cert: dir.appendingPathComponent("ca.crt.pem"),
      key: dir.appendingPathComponent("ca.key.pem")
    )
  }

  private func internalCAURLs() throws -> (cert: URL, key: URL) {
    guard let urls = internalCAURLsIfAvailable() else {
      throw ProxyViewModelError.invalidValue("Could not access Application Support directory")
    }
    try FileManager.default.createDirectory(
      at: urls.cert.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return urls
  }

  private func normalizedKbpsOrMsInt(from raw: UInt64) -> Int {
    if raw > UInt64(Int.max) {
      return Int.max
    }
    return Int(raw)
  }

  private func kbpsInt(fromBytesPerSecond raw: UInt64) -> Int {
    let kbps = raw / 1024
    if kbps > UInt64(Int.max) {
      return Int.max
    }
    return Int(kbps)
  }

  private func parseListenAddressComponents(from rawAddress: String) -> (host: String, port: UInt16)? {
    let raw = trimmed(rawAddress)
    guard !raw.isEmpty else { return nil }

    if let bracketClose = raw.firstIndex(of: "]"),
      raw.first == "[",
      bracketClose < raw.endIndex
    {
      let host = String(raw[raw.startIndex...bracketClose])
      let next = raw.index(after: bracketClose)
      if next < raw.endIndex, raw[next] == ":" {
        let portText = String(raw[raw.index(after: next)...])
        if let port = UInt16(portText) {
          return (host, port)
        }
      }
      return (host, listenPort)
    }

    if let colon = raw.lastIndex(of: ":"), colon < raw.endIndex {
      let host = String(raw[..<colon])
      let portText = String(raw[raw.index(after: colon)...])
      if !host.isEmpty, let port = UInt16(portText) {
        return (host, port)
      }
    }

    return (raw, listenPort)
  }

  private func parseListenAddress() -> (host: String, port: UInt16) {
    let raw = trimmed(listenAddress)
    guard !raw.isEmpty else {
      let host = allowLANConnections ? "0.0.0.0" : "127.0.0.1"
      return (host, listenPort)
    }

    if let bracketClose = raw.firstIndex(of: "]"),
      raw.first == "[",
      bracketClose < raw.endIndex
    {
      let host = String(raw[raw.startIndex...bracketClose])
      let next = raw.index(after: bracketClose)
      if next < raw.endIndex, raw[next] == ":" {
        let portText = String(raw[raw.index(after: next)...])
        if let port = UInt16(portText) {
          return (host, port)
        }
      }
      return (host, listenPort)
    }

    if let colon = raw.lastIndex(of: ":"), colon < raw.endIndex {
      let host = String(raw[..<colon])
      let portText = String(raw[raw.index(after: colon)...])
      if !host.isEmpty, let port = UInt16(portText) {
        return (host, port)
      }
    }

    return (raw, listenPort)
  }

  private func isLoopbackHost(_ host: String) -> Bool {
    let value = host.lowercased()
    return value == "127.0.0.1"
      || value == "localhost"
      || value == "::1"
      || value == "[::1]"
  }

  private func isAllInterfacesHost(_ host: String) -> Bool {
    let value = host.lowercased()
    return value == "0.0.0.0"
      || value == "::"
      || value == "[::]"
  }

  private func preferredLANIPv4Address() -> String? {
    NetworkInterfaceService.preferredLANIPv4Address()
  }

  private func appendLog(level: UInt8, message: String) {
    guard !suppressIncomingLogs else { return }
    handleLANAccessRequestLog(message)
    pendingLogEvents.append((level, message))
    scheduleLogFlushIfNeeded()
  }

  private func handleLANAccessRequestLog(_ message: String) {
    guard let rawIP = Self.firstCapture(Self.lanAccessRequestRegex, in: message) else { return }
    guard let ip = Self.normalizedIPAddress(rawIP) else { return }
    if lanClientAllowlist.contains(ip) {
      return
    }
    if dismissedLANAccessIPs.contains(ip) {
      return
    }
    enqueueLANAccessPrompt(ip)
  }

  private func enqueueLANAccessPrompt(_ ip: String) {
    if pendingLANAccessRequestIP == ip {
      return
    }
    if pendingLANAccessQueue.contains(ip) {
      return
    }
    guard pendingLANAccessRequestIP != nil else {
      pendingLANAccessRequestIP = ip
      return
    }
    pendingLANAccessQueue.append(ip)
  }

  private func advancePendingLANAccessPromptIfNeeded() {
    if let next = pendingLANAccessQueue.first {
      pendingLANAccessQueue.removeFirst()
      pendingLANAccessRequestIP = next
      return
    }
    pendingLANAccessRequestIP = nil
  }

  private func scheduleCaptureRestartIfRunning(taskSlot: inout Task<Void, Never>?) {
    guard isCaptureEnabled else { return }
    taskSlot?.cancel()
    taskSlot = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      guard !Task.isCancelled else { return }
      guard self.isCaptureEnabled else { return }

      self.stopCapture()
      guard !Task.isCancelled else { return }
      guard !self.isCaptureEnabled else { return }

      self.startCapture()
    }
  }

  private func applyAllowLANConnectionsIfRunning(oldValue: Bool) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != allowLANConnections else { return }
    scheduleCaptureRestartIfRunning(taskSlot: &listenAddressApplyTask)
  }

  private func applyLANClientAllowlistIfRunning(oldValue: [String]) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != lanClientAllowlist else { return }
    scheduleCaptureRestartIfRunning(taskSlot: &lanClientAllowlistApplyTask)
  }

  private func applyInspectBodiesIfRunning(oldValue: Bool) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != inspectBodies else { return }
    scheduleCaptureRestartIfRunning(taskSlot: &inspectBodiesApplyTask)
  }

  private func applyThrottleIfRunning(oldValue: Bool) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != throttleEnabled else { return }
    guard isCaptureEnabled else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleLatencyIfRunning(oldValue: Int) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != throttleLatencyMs else { return }
    guard isCaptureEnabled else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleDownstreamIfRunning(oldValue: Int) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != throttleDownstreamKbps else { return }
    guard isCaptureEnabled else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleUpstreamIfRunning(oldValue: Int) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != throttleUpstreamKbps else { return }
    guard isCaptureEnabled else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleOnlySelectedHostsIfRunning(oldValue: Bool) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != throttleOnlySelectedHosts else { return }
    guard isCaptureEnabled else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleSelectedHostsIfRunning(oldValue: [String]) {
    guard !suppressExternalRuntimeConfigApply else { return }
    guard oldValue != throttleSelectedHosts else { return }
    guard isCaptureEnabled else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func scheduleThrottleApplyIfRunning() {
    scheduleCaptureRestartIfRunning(taskSlot: &throttleApplyTask)
  }

  private func scheduleLogFlushIfNeeded() {
    guard logFlushTask == nil else { return }

    logFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: self.logFlushIntervalNanoseconds)
      self.flushLogBatch()
    }
  }

  private func flushLogBatch() {
    logFlushTask = nil
    guard !pendingLogEvents.isEmpty else { return }

    let events = pendingLogEvents
    pendingLogEvents.removeAll(keepingCapacity: true)

    guard
      let snapshot = logStore.appendBatch(
        events,
        currentSelectedLogID: selectedLogID
      )
    else {
      return
    }

    logs = snapshot.logs
    rebuildFilteredLogs()
    if selectedLogID != snapshot.selectedLogID {
      selectedLogID = snapshot.selectedLogID
    }
    scheduleClientAppResolution()
  }

  private func scheduleClientAppResolution() {
    pruneClientAppResolutionState()
    let candidates = logStore.unresolvedClientAppEntries(limit: clientAppResolutionBatchSize)
    guard !candidates.isEmpty else { return }

    for candidate in candidates {
      guard !pendingClientAppResolutionIDs.contains(candidate.id) else { continue }
      let attempts = clientAppResolutionAttempts[candidate.id] ?? 0
      guard attempts < maxClientAppResolutionAttempts else { continue }

      pendingClientAppResolutionIDs.insert(candidate.id)
      clientAppResolutionAttempts[candidate.id] = attempts + 1

      Task { @MainActor [weak self] in
        guard let self else { return }
        let app = await self.clientAppResolver.resolveClientApp(
          peer: candidate.peer,
          platformHint: candidate.clientPlatform
        )
        self.pendingClientAppResolutionIDs.remove(candidate.id)
        if let app, let snapshot = self.logStore.setClientApp(app, forLogID: candidate.id) {
          self.logs = snapshot
          self.rebuildFilteredLogs()
        } else if (self.clientAppResolutionAttempts[candidate.id] ?? 0) < self.maxClientAppResolutionAttempts {
          Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            self?.scheduleClientAppResolution()
          }
        }
      }
    }
  }

  private func pruneClientAppResolutionState() {
    let liveIDs = Set(logs.map(\.id))
    pendingClientAppResolutionIDs = pendingClientAppResolutionIDs.filter { liveIDs.contains($0) }
    clientAppResolutionAttempts = clientAppResolutionAttempts.filter { liveIDs.contains($0.key) }
  }

  private func rebuildFilteredLogs() {
    let needle = trimmed(visibleURLFilter)
    filteredLogs = logs.filter { entry in
      let matchesText = needle.isEmpty
        || entry.url.localizedCaseInsensitiveContains(needle)
        || entry.rawLine.localizedCaseInsensitiveContains(needle)
      let matchesStatus = statusCodeFilter.isEmpty
        || statusCodeCategory(for: entry.statusCode).map { statusCodeFilter.contains($0) } == true
      return matchesText && matchesStatus
    }
  }

  private func statusCodeCategory(for raw: String?) -> StatusCodeCategory? {
    guard let raw, let value = Int(raw) else { return nil }
    return StatusCodeCategory.allCases.first { $0.contains(value) }
  }

  private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func canonicalEnabledMapLocalRules(
    from rules: [MapLocalRuleInput]
  ) -> [CanonicalMapLocalRule] {
    rules.compactMap { rule in
      guard rule.isEnabled else { return nil }
      let matcher = trimmed(rule.matcher)
      let sourceValue = trimmed(rule.sourceValue)
      guard !matcher.isEmpty, !sourceValue.isEmpty else { return nil }
      let statusCode = UInt16(trimmed(rule.statusCode)) ?? 200
      let contentType = {
        let value = trimmed(rule.contentType)
        return value.isEmpty ? nil : value
      }()
      return CanonicalMapLocalRule(
        matcher: matcher,
        sourceType: rule.sourceType,
        sourceValue: sourceValue,
        statusCode: statusCode,
        contentType: contentType
      )
    }
  }

  private func canonicalMapLocalRules(
    from rules: [RuntimeRulesDump.MapLocalEntry]
  ) -> [CanonicalMapLocalRule] {
    rules.map { rule in
      CanonicalMapLocalRule(
        matcher: rule.matcher,
        sourceType: rule.source.kind == .file ? .file : .text,
        sourceValue: rule.source.value,
        statusCode: rule.statusCode,
        contentType: rule.contentType
      )
    }
  }

  private func canonicalEnabledMapRemoteRules(
    from rules: [MapRemoteRuleInput]
  ) -> [CanonicalMapRemoteRule] {
    rules.compactMap { rule in
      guard rule.isEnabled else { return nil }
      let matcher = trimmed(rule.matcher)
      let destinationURL = trimmed(rule.destinationURL)
      guard !matcher.isEmpty, !destinationURL.isEmpty else { return nil }
      return CanonicalMapRemoteRule(matcher: matcher, destinationURL: destinationURL)
    }
  }

  private func canonicalMapRemoteRules(
    from rules: [RuntimeRulesDump.MapRemoteEntry]
  ) -> [CanonicalMapRemoteRule] {
    rules.map { CanonicalMapRemoteRule(matcher: $0.matcher, destinationURL: $0.destination) }
  }

  private func canonicalEnabledStatusRewriteRules(
    from rules: [StatusRewriteRuleInput]
  ) -> [CanonicalStatusRewriteRule] {
    rules.compactMap { rule in
      guard rule.isEnabled else { return nil }
      let matcher = trimmed(rule.matcher)
      guard !matcher.isEmpty else { return nil }
      let fromStatusCode = UInt16(trimmed(rule.fromStatusCode))
      let toStatusCode = UInt16(trimmed(rule.toStatusCode)) ?? 200
      return CanonicalStatusRewriteRule(
        matcher: matcher,
        fromStatusCode: fromStatusCode,
        toStatusCode: toStatusCode
      )
    }
  }

  private func canonicalStatusRewriteRules(
    from rules: [RuntimeRulesDump.StatusRewriteEntry]
  ) -> [CanonicalStatusRewriteRule] {
    rules.map {
      CanonicalStatusRewriteRule(
        matcher: $0.matcher,
        fromStatusCode: $0.fromStatusCode,
        toStatusCode: $0.toStatusCode
      )
    }
  }

  private func mapLocalRuleInputs(
    from rules: [RuntimeRulesDump.MapLocalEntry]
  ) -> [MapLocalRuleInput] {
    rules.map { rule in
      MapLocalRuleInput(
        isEnabled: true,
        matcher: rule.matcher,
        sourceType: rule.source.kind == .file ? .file : .text,
        sourceValue: rule.source.value,
        statusCode: String(rule.statusCode),
        contentType: rule.contentType ?? ""
      )
    }
  }

  private func mapRemoteRuleInputs(
    from rules: [RuntimeRulesDump.MapRemoteEntry]
  ) -> [MapRemoteRuleInput] {
    rules.map { rule in
      MapRemoteRuleInput(
        isEnabled: true,
        matcher: rule.matcher,
        destinationURL: rule.destination
      )
    }
  }

  private func statusRewriteRuleInputs(
    from rules: [RuntimeRulesDump.StatusRewriteEntry]
  ) -> [StatusRewriteRuleInput] {
    rules.map { rule in
      StatusRewriteRuleInput(
        isEnabled: true,
        matcher: rule.matcher,
        fromStatusCode: rule.fromStatusCode.map(String.init) ?? "",
        toStatusCode: String(rule.toStatusCode)
      )
    }
  }

  private func domainName(from urlString: String) -> String {
    if let host = URLComponents(string: urlString)?.host, !host.isEmpty {
      return host.lowercased()
    }
    return "(unknown)"
  }

  private func bindPersistence() {
    $allowRules
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistAllowRules()
      }
      .store(in: &cancellables)

    $mapLocalRules
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistMapLocalRules()
      }
      .store(in: &cancellables)

    $mapRemoteRules
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistMapRemoteRules()
      }
      .store(in: &cancellables)

    $statusRewriteRules
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistStatusRewriteRules()
      }
      .store(in: &cancellables)

    $allowLANConnections
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistListenSettings()
      }
      .store(in: &cancellables)

    $lanClientAllowlist
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistListenSettings()
      }
      .store(in: &cancellables)

    $throttleEnabled
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistThrottleSettings()
      }
      .store(in: &cancellables)

    $throttleLatencyMs
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistThrottleSettings()
      }
      .store(in: &cancellables)

    $throttleDownstreamKbps
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistThrottleSettings()
      }
      .store(in: &cancellables)

    $throttleUpstreamKbps
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistThrottleSettings()
      }
      .store(in: &cancellables)

    $throttleOnlySelectedHosts
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistThrottleSettings()
      }
      .store(in: &cancellables)

    $throttleSelectedHosts
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistThrottleSettings()
      }
      .store(in: &cancellables)
  }

  private func defaultMapLocalMatcher(from urlString: String) -> String {
    guard var components = URLComponents(string: urlString) else {
      return urlString
    }
    components.query = nil
    components.fragment = nil
    if let scheme = components.scheme?.lowercased(),
      let port = components.port,
      isDefaultPort(port, scheme: scheme)
    {
      components.port = nil
    }
    return components.string ?? urlString
  }

  private func defaultAllowMatcher(from urlString: String) -> String? {
    if let components = URLComponents(string: urlString),
      let host = components.host,
      !host.isEmpty
    {
      if let port = components.port,
        let scheme = components.scheme?.lowercased(),
        !isDefaultPort(port, scheme: scheme)
      {
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
      }
      return host
    }

    return allowMatcherCandidate(fromRawMatcher: urlString)
  }

  private func isDefaultPort(_ port: Int, scheme: String) -> Bool {
    (scheme == "https" && port == 443)
      || (scheme == "http" && port == 80)
  }

  private func mergedAllowRulesForMappedRules(
    allowRules: [AllowRuleInput],
    mapLocalRules: [MapLocalRuleInput],
    mapRemoteRules: [MapRemoteRuleInput]
  ) -> [AllowRuleInput] {
    // Empty allowlist means "allow all"; don't force a restrictive list.
    guard !allowRules.isEmpty else { return allowRules }

    var merged = allowRules
    var seen: Set<String> = Set(
      allowRules.map { $0.matcher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    )

    for rule in mapLocalRules {
      if !rule.isEnabled {
        continue
      }
      guard
        let matcher = allowMatcherCandidate(fromRawMatcher: rule.matcher)
      else { continue }

      let normalized = matcher.lowercased()
      if seen.insert(normalized).inserted {
        merged.append(AllowRuleInput(matcher: matcher))
      }
    }

    for rule in mapRemoteRules {
      if !rule.isEnabled {
        continue
      }
      guard
        let matcher = allowMatcherCandidate(fromRawMatcher: rule.matcher)
      else { continue }

      let normalized = matcher.lowercased()
      if seen.insert(normalized).inserted {
        merged.append(AllowRuleInput(matcher: matcher))
      }
    }

    return merged
  }

  private func allowMatcherCandidate(fromRawMatcher raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let components = URLComponents(string: trimmed),
      let host = components.host,
      !host.isEmpty
    {
      return host
    }

    if trimmed.hasPrefix("/") {
      return nil
    }

    let authorityAndMaybePath: String
    if let slash = trimmed.firstIndex(of: "/") {
      authorityAndMaybePath = String(trimmed[..<slash])
    } else {
      authorityAndMaybePath = trimmed
    }

    if authorityAndMaybePath.isEmpty {
      return nil
    }

    if authorityAndMaybePath.hasPrefix("["),
      let close = authorityAndMaybePath.firstIndex(of: "]")
    {
      return String(authorityAndMaybePath[...close])
    }

    if let colon = authorityAndMaybePath.firstIndex(of: ":") {
      let host = String(authorityAndMaybePath[..<colon])
      return host.isEmpty ? nil : host
    }

    return authorityAndMaybePath
  }

  private func persistListenSettings() {
    let defaults = UserDefaults.standard
    defaults.set(
      allowLANConnections,
      forKey: Self.allowLANConnectionsDefaultsKey
    )
    defaults.set(
      Self.normalizedLANClientAllowlist(lanClientAllowlist),
      forKey: Self.lanClientAllowlistDefaultsKey
    )
  }

  private func persistAllowRules() {
    let values = ruleManager.normalizedAllowMatchers(from: allowRules)
    UserDefaults.standard.set(values, forKey: Self.allowRulesDefaultsKey)
  }

  private func persistMapLocalRules() {
    let payload = mapLocalRules.map { rule in
      PersistedMapLocalRule(
        isEnabled: rule.isEnabled,
        matcher: rule.matcher,
        sourceType: rule.sourceType.rawValue,
        sourceValue: rule.sourceValue,
        statusCode: rule.statusCode,
        contentType: rule.contentType
      )
    }
    guard let data = try? JSONEncoder().encode(payload) else { return }
    UserDefaults.standard.set(data, forKey: Self.mapLocalRulesDefaultsKey)
  }

  private func persistMapRemoteRules() {
    let payload = mapRemoteRules.map { rule in
      PersistedMapRemoteRule(
        isEnabled: rule.isEnabled,
        matcher: rule.matcher,
        destinationURL: rule.destinationURL
      )
    }
    guard let data = try? JSONEncoder().encode(payload) else { return }
    UserDefaults.standard.set(data, forKey: Self.mapRemoteRulesDefaultsKey)
  }

  private func persistStatusRewriteRules() {
    let payload = statusRewriteRules.map { rule in
      PersistedStatusRewriteRule(
        isEnabled: rule.isEnabled,
        matcher: rule.matcher,
        fromStatusCode: rule.fromStatusCode,
        toStatusCode: rule.toStatusCode
      )
    }
    guard let data = try? JSONEncoder().encode(payload) else { return }
    UserDefaults.standard.set(data, forKey: Self.statusRewriteRulesDefaultsKey)
  }

  private func persistThrottleSettings() {
    let defaults = UserDefaults.standard
    defaults.set(throttleEnabled, forKey: Self.throttleEnabledDefaultsKey)
    defaults.set(
      Self.normalizedNonNegativeInt(throttleLatencyMs),
      forKey: Self.throttleLatencyMsDefaultsKey
    )
    defaults.set(
      Self.normalizedNonNegativeInt(throttleDownstreamKbps),
      forKey: Self.throttleDownstreamKbpsDefaultsKey
    )
    defaults.set(
      Self.normalizedNonNegativeInt(throttleUpstreamKbps),
      forKey: Self.throttleUpstreamKbpsDefaultsKey
    )
    defaults.set(
      throttleOnlySelectedHosts,
      forKey: Self.throttleOnlySelectedHostsDefaultsKey
    )
    defaults.set(
      Self.normalizedThrottleHosts(throttleSelectedHosts),
      forKey: Self.throttleSelectedHostsDefaultsKey
    )
  }

  private static func loadAllowRules() -> [AllowRuleInput] {
    let defaults = UserDefaults.standard
    let key = Self.allowRulesDefaultsKey

    guard defaults.object(forKey: key) != nil else {
      return []
    }

    let saved = defaults.stringArray(forKey: key) ?? []
    if saved.isEmpty {
      return []
    }

    return saved.map { AllowRuleInput(matcher: $0) }
  }

  private static func loadAllowLANConnections() -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Self.allowLANConnectionsDefaultsKey) != nil else {
      return true
    }
    return defaults.bool(forKey: Self.allowLANConnectionsDefaultsKey)
  }

  private static func loadLANClientAllowlist() -> [String] {
    let defaults = UserDefaults.standard
    let raw = defaults.stringArray(forKey: Self.lanClientAllowlistDefaultsKey) ?? []
    return normalizedLANClientAllowlist(raw)
  }

  private static func loadMapLocalRules() -> [MapLocalRuleInput] {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: Self.mapLocalRulesDefaultsKey) else {
      return []
    }
    guard let saved = try? JSONDecoder().decode([PersistedMapLocalRule].self, from: data) else {
      return []
    }

    return saved.map { item in
      MapLocalRuleInput(
        isEnabled: item.isEnabled ?? true,
        matcher: item.matcher,
        sourceType: RuleSourceType(rawValue: item.sourceType) ?? .file,
        sourceValue: item.sourceValue,
        statusCode: item.statusCode,
        contentType: item.contentType
      )
    }
  }

  private static func loadMapRemoteRules() -> [MapRemoteRuleInput] {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: Self.mapRemoteRulesDefaultsKey) else {
      return []
    }
    guard let saved = try? JSONDecoder().decode([PersistedMapRemoteRule].self, from: data) else {
      return []
    }

    return saved.map { item in
      MapRemoteRuleInput(
        isEnabled: item.isEnabled ?? true,
        matcher: item.matcher,
        destinationURL: item.destinationURL
      )
    }
  }

  private static func loadStatusRewriteRules() -> [StatusRewriteRuleInput] {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: Self.statusRewriteRulesDefaultsKey) else {
      return []
    }
    guard
      let saved = try? JSONDecoder().decode([PersistedStatusRewriteRule].self, from: data)
    else {
      return []
    }

    return saved.map { item in
      StatusRewriteRuleInput(
        isEnabled: item.isEnabled ?? true,
        matcher: item.matcher,
        fromStatusCode: item.fromStatusCode,
        toStatusCode: item.toStatusCode
      )
    }
  }

  private static func loadThrottleEnabled() -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Self.throttleEnabledDefaultsKey) != nil else {
      return false
    }
    return defaults.bool(forKey: Self.throttleEnabledDefaultsKey)
  }

  private static func loadThrottleLatencyMs() -> Int {
    let defaults = UserDefaults.standard
    let raw = defaults.integer(forKey: Self.throttleLatencyMsDefaultsKey)
    return normalizedNonNegativeInt(raw)
  }

  private static func loadThrottleDownstreamKbps() -> Int {
    let defaults = UserDefaults.standard
    let raw = defaults.integer(forKey: Self.throttleDownstreamKbpsDefaultsKey)
    return normalizedNonNegativeInt(raw)
  }

  private static func loadThrottleUpstreamKbps() -> Int {
    let defaults = UserDefaults.standard
    let raw = defaults.integer(forKey: Self.throttleUpstreamKbpsDefaultsKey)
    return normalizedNonNegativeInt(raw)
  }

  private static func loadThrottleOnlySelectedHosts() -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Self.throttleOnlySelectedHostsDefaultsKey) != nil else {
      return false
    }
    return defaults.bool(forKey: Self.throttleOnlySelectedHostsDefaultsKey)
  }

  private static func loadThrottleSelectedHosts() -> [String] {
    let defaults = UserDefaults.standard
    let raw = defaults.stringArray(forKey: Self.throttleSelectedHostsDefaultsKey) ?? []
    return normalizedThrottleHosts(raw)
  }

  private static func normalizedLANClientAllowlist(_ values: [String]) -> [String] {
    var out: [String] = []
    var seen: Set<String> = []
    for raw in values {
      guard let normalized = normalizedIPAddress(raw) else { continue }
      let lowered = normalized.lowercased()
      guard seen.insert(lowered).inserted else { continue }
      out.append(normalized)
    }
    return out
  }

  private static func normalizedIPAddress(_ value: String) -> String? {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    if let v4 = IPv4Address(raw) {
      return v4.debugDescription
    }
    if let v6 = IPv6Address(raw) {
      return v6.debugDescription.lowercased()
    }
    return nil
  }

  private static func normalizedThrottleHosts(_ values: [String]) -> [String] {
    var out: [String] = []
    var seen: Set<String> = []
    for raw in values {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let lowered = trimmed.lowercased()
      guard seen.insert(lowered).inserted else { continue }
      out.append(trimmed)
    }
    return out
  }

  private static let lanAccessRequestRegex = try! NSRegularExpression(
    pattern: #"LAN_ACCESS_REQUEST ip=([^\s]+)"#
  )

  private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1
    else { return nil }
    guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[captureRange])
  }

  private static func normalizedNonNegativeInt(_ value: Int) -> Int {
    max(0, value)
  }
}
