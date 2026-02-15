import Combine
import Foundation

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

  private struct PersistedMapLocalRule: Codable {
    var isEnabled: Bool?
    var matcher: String
    var sourceType: String
    var sourceValue: String
    var statusCode: String
    var contentType: String
  }

  private struct PersistedStatusRewriteRule: Codable {
    var isEnabled: Bool?
    var matcher: String
    var fromStatusCode: String
    var toStatusCode: String
  }

  let certPortalURL = "http://crab-proxy.local/"
  let listenAddress = "0.0.0.0:8888"
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
  @Published var isRunning = false
  @Published var statusText = "Stopped"
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
  @Published var stagedAllowRule: AllowRuleInput?
  @Published var stagedStatusRewriteRule: StatusRewriteRuleInput?
  @Published var allowRules: [AllowRuleInput] = []
  @Published var mapLocalRules: [MapLocalRuleInput] = []
  @Published var statusRewriteRules: [StatusRewriteRuleInput] = []

  private var engine: RustProxyEngine?
  private let logStore = ProxyLogStore(maxLogEntries: 800)
  private let ruleManager = ProxyRuleManager()
  private static let allowRulesDefaultsKey = "CrabProxyMacApp.allowRules"
  private static let mapLocalRulesDefaultsKey = "CrabProxyMacApp.mapLocalRules.v1"
  private static let statusRewriteRulesDefaultsKey = "CrabProxyMacApp.statusRewriteRules.v1"
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
  private let transparentProxyPort: UInt16 = 8889
  private let caCertService: any CACertServicing
  private let pfService: any PFServicing
  private let systemProxyService: any MacSystemProxyServicing
  private var pendingLogEvents: [(level: UInt8, message: String)] = []
  private var logFlushTask: Task<Void, Never>?
  private var inspectBodiesApplyTask: Task<Void, Never>?
  private var throttleApplyTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(
    systemProxyService: any MacSystemProxyServicing = LiveMacSystemProxyService(),
    pfService: any PFServicing = LivePFService(),
    caCertService: any CACertServicing = LiveCACertService()
  ) {
    self.caCertService = caCertService
    self.pfService = pfService
    self.systemProxyService = systemProxyService
    allowRules = Self.loadAllowRules()
    mapLocalRules = Self.loadMapLocalRules()
    statusRewriteRules = Self.loadStatusRewriteRules()
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
      self.engine = try makeEngine()
      self.statusText = "Ready"
    } catch {
      self.statusText = "Init failed: \(error.localizedDescription)"
    }
    rebuildFilteredLogs()
  }

  deinit {
    logFlushTask?.cancel()
    inspectBodiesApplyTask?.cancel()
    throttleApplyTask?.cancel()
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
    if isLoopbackHost(listen.host) || isAllInterfacesHost(listen.host) {
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
      return "For iOS/Android, change Listen to 0.0.0.0:\(listen.port) and use Mac LAN IP below."
    }
    if isAllInterfacesHost(listen.host) {
      return "Use the Mac LAN IP below as proxy server on phone."
    }
    return "Phone proxy server should match this host:port."
  }

  func startProxy() {
    guard let engine else {
      statusText = "Engine not initialized"
      return
    }

    do {
      try engine.setListenAddress(listenAddress)
      try engine.setInspectEnabled(inspectBodies)
      try applyThrottleConfig(to: engine)
      if transparentProxyEnabled {
        try engine.setTransparentEnabled(true)
        try engine.setTransparentPort(transparentProxyPort)
      }
      try syncRules(to: engine)
      try ensureInternalCALoaded(engine: engine)

      try engine.start()
      isRunning = engine.isRunning()
      statusText = isRunning ? "Running" : "Stopped"
    } catch {
      isRunning = false
      statusText = "Start failed: \(error.localizedDescription)"
    }
  }

  func stopProxy() {
    guard engine != nil else {
      statusText = "Engine not initialized"
      return
    }

    var failure: Error?
    if let engine {
      do {
        try engine.stop()
      } catch {
        failure = error
      }
    }

    do {
      try recreateEngine()
      isRunning = false
      statusText = failure == nil ? "Stopped" : "Stopped (forced reset)"
    } catch {
      isRunning = self.engine?.isRunning() ?? false
      if let failure {
        statusText = "Stop failed: \(failure.localizedDescription); reset failed: \(error.localizedDescription)"
      } else {
        statusText = "Stop failed: \(error.localizedDescription)"
      }
    }
  }

  func clearLogs() {
    logFlushTask?.cancel()
    logFlushTask = nil
    pendingLogEvents.removeAll(keepingCapacity: true)
    logs = logStore.clear()
    filteredLogs.removeAll(keepingCapacity: true)
    selectedLogID = nil
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

  func enableTransparentProxy() {
    guard !isApplyingTransparentProxy else { return }
    isApplyingTransparentProxy = true
    let pfService = self.pfService
    let transparentProxyPort = self.transparentProxyPort
    let certPathToInstall = caCertInstalledInKeychain ? nil : (caCertPath.isEmpty ? nil : caCertPath)

    Task {
      defer { isApplyingTransparentProxy = false }
      do {
        let wasRunning = engine?.isRunning() ?? false
        if wasRunning {
          stopProxy()
        }

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

        if wasRunning {
          startProxy()
        }

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

        if let engine {
          let wasRunning = engine.isRunning()
          if wasRunning {
            stopProxy()
          }
          try engine.setTransparentEnabled(false)
          if wasRunning {
            startProxy()
          }
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
    guard !isRunning else {
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
    statusRewriteRules: [StatusRewriteRuleInput]
  ) {
    let mergedAllowRules = mergedAllowRulesForMapLocal(
      allowRules: allowRules,
      mapLocalRules: mapLocalRules
    )

    do {
      try ruleManager.validateRules(
        allowRules: mergedAllowRules,
        mapLocalRules: mapLocalRules,
        statusRewriteRules: statusRewriteRules
      )
    } catch {
      statusText = "Save failed: \(error.localizedDescription)"
      return
    }

    self.allowRules = mergedAllowRules
    self.mapLocalRules = mapLocalRules
    self.statusRewriteRules = statusRewriteRules
    // Persist immediately so values survive app/tab transitions even if app exits quickly.
    persistAllowRules()
    persistMapLocalRules()
    persistStatusRewriteRules()

    do {
      let runtimeWasRunning = try applyRulesToEngineAfterSave()
      statusText = runtimeWasRunning ? "Rules saved and applied" : "Rules saved"
    } catch {
      isRunning = engine?.isRunning() ?? false
      statusText = "Save failed: \(error.localizedDescription)"
    }
  }

  private func applyRulesToEngineAfterSave() throws -> Bool {
    guard let engine else {
      return false
    }

    let runtimeWasRunning = engine.isRunning()
    if runtimeWasRunning {
      try engine.stop()
      try recreateEngine()
    }

    guard let activeEngine = self.engine else {
      throw ProxyViewModelError.invalidValue("Engine not initialized")
    }
    try syncRules(to: activeEngine)

    if runtimeWasRunning {
      try activeEngine.setListenAddress(listenAddress)
      try activeEngine.setInspectEnabled(inspectBodies)
      try applyThrottleConfig(to: activeEngine)
      if transparentProxyEnabled {
        try activeEngine.setTransparentEnabled(true)
        try activeEngine.setTransparentPort(transparentProxyPort)
      }
      try ensureInternalCALoaded(engine: activeEngine)
      try activeEngine.start()
    }

    isRunning = activeEngine.isRunning()
    return runtimeWasRunning
  }

  private func makeEngine() throws -> RustProxyEngine {
    let engine = try RustProxyEngine(listenAddress: listenAddress)
    engine.onLog = { [weak self] level, message in
      Task { @MainActor [weak self] in
        self?.appendLog(level: level, message: message)
      }
    }
    return engine
  }

  private func recreateEngine() throws {
    engine = nil
    engine = try makeEngine()
  }

  private func applyMacSystemProxyStatus(_ status: MacSystemProxyStatus) {
    macSystemProxyEnabled = status.isEnabled
    macSystemProxyServiceText = "\(status.networkService) (\(status.interfaceName))"
    macSystemProxyStateText = status.isEnabled ? "ON • \(status.activeEndpoint)" : "OFF"
  }

  private func syncRules(to engine: RustProxyEngine) throws {
    try ruleManager.syncRules(
      to: engine,
      allowRules: allowRules,
      mapLocalRules: mapLocalRules,
      statusRewriteRules: statusRewriteRules
    )
  }

  private func applyThrottleConfig(to engine: RustProxyEngine) throws {
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

  private func ensureInternalCALoaded(engine: RustProxyEngine) throws {
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

  private func parseListenAddress() -> (host: String, port: UInt16) {
    let raw = trimmed(listenAddress)
    guard !raw.isEmpty else {
      return ("0.0.0.0", 8888)
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
      return (host, 8888)
    }

    if let colon = raw.lastIndex(of: ":"), colon < raw.endIndex {
      let host = String(raw[..<colon])
      let portText = String(raw[raw.index(after: colon)...])
      if !host.isEmpty, let port = UInt16(portText) {
        return (host, port)
      }
    }

    return (raw, 8888)
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
    pendingLogEvents.append((level, message))
    scheduleLogFlushIfNeeded()
  }

  private func applyInspectBodiesIfRunning(oldValue: Bool) {
    guard oldValue != inspectBodies else { return }
    guard isRunning else { return }
    inspectBodiesApplyTask?.cancel()

    inspectBodiesApplyTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      guard !Task.isCancelled else { return }
      guard self.isRunning else { return }

      self.stopProxy()
      guard !Task.isCancelled else { return }
      guard !self.isRunning else { return }

      self.startProxy()
    }
  }

  private func applyThrottleIfRunning(oldValue: Bool) {
    guard oldValue != throttleEnabled else { return }
    guard isRunning else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleLatencyIfRunning(oldValue: Int) {
    guard oldValue != throttleLatencyMs else { return }
    guard isRunning else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleDownstreamIfRunning(oldValue: Int) {
    guard oldValue != throttleDownstreamKbps else { return }
    guard isRunning else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleUpstreamIfRunning(oldValue: Int) {
    guard oldValue != throttleUpstreamKbps else { return }
    guard isRunning else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleOnlySelectedHostsIfRunning(oldValue: Bool) {
    guard oldValue != throttleOnlySelectedHosts else { return }
    guard isRunning else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func applyThrottleSelectedHostsIfRunning(oldValue: [String]) {
    guard oldValue != throttleSelectedHosts else { return }
    guard isRunning else { return }
    scheduleThrottleApplyIfRunning()
  }

  private func scheduleThrottleApplyIfRunning() {
    guard isRunning else { return }
    throttleApplyTask?.cancel()

    throttleApplyTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      guard !Task.isCancelled else { return }
      guard self.isRunning else { return }

      self.stopProxy()
      guard !Task.isCancelled else { return }
      guard !self.isRunning else { return }

      self.startProxy()
    }
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

    $statusRewriteRules
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistStatusRewriteRules()
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

  private func mergedAllowRulesForMapLocal(
    allowRules: [AllowRuleInput],
    mapLocalRules: [MapLocalRuleInput]
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

  private static func normalizedNonNegativeInt(_ value: Int) -> Int {
    max(0, value)
  }
}
