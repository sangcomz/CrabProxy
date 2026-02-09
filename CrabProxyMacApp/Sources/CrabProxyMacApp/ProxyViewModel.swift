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
  let certPortalURL = "http://crab-proxy.invalid/"
  let listenAddress = "0.0.0.0:8888"
  @Published private(set) var caCertPath = ""
  @Published private(set) var caStatusText = "Preparing internal CA"
  @Published var inspectBodies = true {
    didSet {
      applyInspectBodiesIfRunning(oldValue: oldValue)
    }
  }
  @Published var isRunning = false
  @Published var statusText = "Stopped"
  @Published var visibleURLFilter = "" {
    didSet { rebuildFilteredLogs() }
  }
  @Published private(set) var macSystemProxyEnabled = false
  @Published private(set) var macSystemProxyServiceText = "Unknown"
  @Published private(set) var macSystemProxyStateText = "Unknown"
  @Published private(set) var isApplyingMacSystemProxy = false
  @Published private(set) var logs: [ProxyLogEntry] = []
  @Published private(set) var filteredLogs: [ProxyLogEntry] = []
  @Published var selectedLogID: ProxyLogEntry.ID?
  @Published var allowRules: [AllowRuleInput] = []
  @Published var mapLocalRules: [MapLocalRuleInput] = []
  @Published var statusRewriteRules: [StatusRewriteRuleInput] = []

  private var engine: RustProxyEngine?
  private let logStore = ProxyLogStore(maxLogEntries: 800)
  private let ruleManager = ProxyRuleManager()
  private static let allowRulesDefaultsKey = "CrabProxyMacApp.allowRules"
  private static let defaultAllowRuleMatcher = "*.*"
  private let internalCACommonName = "Crab Proxy Internal Root CA"
  private let internalCADays: UInt32 = 3650
  private let logFlushIntervalNanoseconds: UInt64 = 50_000_000
  private let systemProxyService: any MacSystemProxyServicing
  private var pendingLogEvents: [(level: UInt8, message: String)] = []
  private var logFlushTask: Task<Void, Never>?
  private var inspectBodiesApplyTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(systemProxyService: any MacSystemProxyServicing = LiveMacSystemProxyService()) {
    self.systemProxyService = systemProxyService
    allowRules = Self.loadAllowRules()
    bindPersistence()
    refreshInternalCAStatus()
    refreshMacSystemProxyStatus()
    do {
      let engine = try RustProxyEngine(listenAddress: listenAddress)
      engine.onLog = { [weak self] level, message in
        Task { @MainActor [weak self] in
          self?.appendLog(level: level, message: message)
        }
      }
      self.engine = engine
      self.statusText = "Ready"
    } catch {
      self.statusText = "Init failed: \(error.localizedDescription)"
    }
    rebuildFilteredLogs()
  }

  deinit {
    logFlushTask?.cancel()
    inspectBodiesApplyTask?.cancel()
  }

  var selectedLog: ProxyLogEntry? {
    logStore.selectedLog(id: selectedLogID)
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
      try syncRules(to: engine)
      try ensureInternalCALoaded(engine: engine)

      try engine.start()
      isRunning = engine.isRunning()
      statusText = "Running"
    } catch {
      isRunning = false
      statusText = "Start failed: \(error.localizedDescription)"
    }
  }

  func stopProxy() {
    guard let engine else {
      statusText = "Engine not initialized"
      return
    }

    do {
      try engine.stop()
      isRunning = false
      statusText = "Stopped"
    } catch {
      statusText = "Stop failed: \(error.localizedDescription)"
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
    guard !needle.isEmpty else {
      filteredLogs = logs
      return
    }
    filteredLogs = logs.filter { entry in
      entry.url.localizedCaseInsensitiveContains(needle)
        || entry.rawLine.localizedCaseInsensitiveContains(needle)
    }
  }

  private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func bindPersistence() {
    $allowRules
      .dropFirst()
      .sink { [weak self] _ in
        self?.persistAllowRules()
      }
      .store(in: &cancellables)
  }

  private func persistAllowRules() {
    let values = ruleManager.normalizedAllowMatchers(from: allowRules)
    UserDefaults.standard.set(values, forKey: Self.allowRulesDefaultsKey)
  }

  private static func loadAllowRules() -> [AllowRuleInput] {
    let defaults = UserDefaults.standard
    let key = Self.allowRulesDefaultsKey

    guard defaults.object(forKey: key) != nil else {
      return [AllowRuleInput(matcher: Self.defaultAllowRuleMatcher)]
    }

    let saved = defaults.stringArray(forKey: key) ?? []
    if saved.isEmpty {
      return []
    }

    return saved.map { AllowRuleInput(matcher: $0) }
  }
}
