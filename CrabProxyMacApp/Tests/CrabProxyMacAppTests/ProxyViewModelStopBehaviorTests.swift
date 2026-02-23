import Foundation
import XCTest

@testable import CrabProxyMacApp

@MainActor
final class ProxyViewModelStopBehaviorTests: XCTestCase {
  override func setUp() {
    super.setUp()
    Self.clearProxyDefaults()
  }

  override func tearDown() {
    Self.clearProxyDefaults()
    super.tearDown()
  }

  func testStartProxyWhenAlreadyRunningKeepsRunningWithoutRestart() async throws {
    let engine = MockProxyEngine(running: true)
    let engineFactory = MockEngineFactory(engines: [engine])

    let model = ProxyViewModel(
      systemProxyService: MockMacSystemProxyService(initialStatus: .disabled),
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    XCTAssertTrue(model.isRunning)

    model.startProxy()

    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(model.statusText, "Running")
    XCTAssertFalse(engine.calls.contains("stop"))
    XCTAssertFalse(engine.calls.contains("start"))
  }

  func testStartProxyFailureSetsErrorStatusAndLeavesStopped() async throws {
    let engine = MockProxyEngine(running: false)
    engine.setListenAddressError = MockError.boom
    let engineFactory = MockEngineFactory(engines: [engine])

    let model = ProxyViewModel(
      systemProxyService: MockMacSystemProxyService(initialStatus: .disabled),
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    XCTAssertFalse(model.isRunning)

    model.startProxy()

    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.statusText.contains("Start failed:"))
    XCTAssertTrue(engine.calls.contains(where: { $0.hasPrefix("setListenAddress(") }))
    XCTAssertFalse(engine.calls.contains("start"))
  }

  func testStopProxySuccessTransitionsToBypassMode() async throws {
    let firstEngine = MockProxyEngine(running: true)
    let bypassEngine = MockProxyEngine(running: false)
    let engineFactory = MockEngineFactory(engines: [firstEngine, bypassEngine])
    let systemProxy = MockMacSystemProxyService(initialStatus: .disabled)

    let model = ProxyViewModel(
      systemProxyService: systemProxy,
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    XCTAssertTrue(model.isRunning)

    model.stopProxy()

    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.statusText, "Stopped")
    XCTAssertTrue(firstEngine.calls.contains("stop"))
    XCTAssertTrue(bypassEngine.calls.contains("setInspectEnabled(false)"))
    XCTAssertTrue(bypassEngine.calls.contains("clearRules"))
    XCTAssertTrue(bypassEngine.calls.contains("start"))
    XCTAssertEqual(systemProxy.disableCallCount, 0)
  }

  func testStopProxyFailureWithRuntimeDownDisablesSystemProxyForRecovery() async throws {
    let firstEngine = MockProxyEngine(running: true)
    let failingBypassEngine = MockProxyEngine(running: false)
    failingBypassEngine.setListenAddressError = MockError.boom
    let engineFactory = MockEngineFactory(engines: [firstEngine, failingBypassEngine])
    let systemProxy = MockMacSystemProxyService(initialStatus: .enabled(host: "127.0.0.1", port: 8888))

    let model = ProxyViewModel(
      systemProxyService: systemProxy,
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    try await waitUntil { model.macSystemProxyEnabled }

    model.stopProxy()

    try await waitUntil { systemProxy.disableCallCount == 1 }
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.statusText.contains("Stop failed:"))
    XCTAssertTrue(model.statusText.contains("disabled macOS system proxy for recovery"))
  }

  func testStopProxyFailureWithRuntimeStillRunningDoesNotDisableSystemProxy() async throws {
    let firstEngine = MockProxyEngine(running: true)
    firstEngine.stopError = MockError.boom
    let engineFactory = MockEngineFactory(engines: [firstEngine])
    let systemProxy = MockMacSystemProxyService(initialStatus: .enabled(host: "127.0.0.1", port: 8888))

    let model = ProxyViewModel(
      systemProxyService: systemProxy,
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    try await waitUntil { model.macSystemProxyEnabled }

    model.stopProxy()

    XCTAssertTrue(model.isRunning)
    XCTAssertTrue(model.statusText.contains("proxy still running"))
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(systemProxy.disableCallCount, 0)
  }

  func testSaveRulesWhileBypassRuntimeActiveDefersRuntimeRuleSync() async throws {
    let firstEngine = MockProxyEngine(running: true)
    let bypassEngine = MockProxyEngine(running: false)
    let engineFactory = MockEngineFactory(engines: [firstEngine, bypassEngine])

    let model = ProxyViewModel(
      systemProxyService: MockMacSystemProxyService(initialStatus: .disabled),
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    model.stopProxy()
    XCTAssertFalse(model.isRunning)

    let callCountBeforeSave = bypassEngine.calls.count
    model.saveRules(
      allowRules: [AllowRuleInput(matcher: "example.com")],
      mapLocalRules: [],
      mapRemoteRules: [],
      statusRewriteRules: []
    )

    XCTAssertEqual(model.statusText, "Rules saved")
    let newCalls = Array(bypassEngine.calls.dropFirst(callCountBeforeSave))
    XCTAssertEqual(newCalls, ["isRunning"])
  }

  func testSaveRulesWhileStoppedSyncsRulesToDaemonConfig() async throws {
    let engine = MockProxyEngine(running: false)
    let engineFactory = MockEngineFactory(engines: [engine])

    let model = ProxyViewModel(
      systemProxyService: MockMacSystemProxyService(initialStatus: .disabled),
      pfService: NoopPFService(),
      caCertService: NoopCACertService(),
      engineFactory: engineFactory.make
    )

    let callCountBeforeSave = engine.calls.count
    model.saveRules(
      allowRules: [AllowRuleInput(matcher: "api.example.com")],
      mapLocalRules: [],
      mapRemoteRules: [],
      statusRewriteRules: []
    )

    XCTAssertEqual(model.statusText, "Rules saved")
    let newCalls = Array(engine.calls.dropFirst(callCountBeforeSave))
    XCTAssertTrue(newCalls.contains("isRunning"))
    XCTAssertTrue(newCalls.contains("clearRules"))
    XCTAssertTrue(newCalls.contains("addAllowRule(api.example.com)"))
    XCTAssertFalse(newCalls.contains("start"))
    XCTAssertFalse(newCalls.contains("stop"))
  }

  private func waitUntil(
    timeout: TimeInterval = 1.5,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() {
        return
      }
      try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    XCTFail("Timed out waiting for condition")
  }

  private nonisolated static func clearProxyDefaults() {
    let defaults = UserDefaults.standard
    [
      "CrabProxyMacApp.allowRules",
      "CrabProxyMacApp.mapLocalRules.v1",
      "CrabProxyMacApp.mapRemoteRules.v1",
      "CrabProxyMacApp.statusRewriteRules.v1",
      "CrabProxyMacApp.network.allowLANConnections.v1",
      "CrabProxyMacApp.network.lanClientAllowlist.v1",
      "CrabProxyMacApp.throttle.enabled.v1",
      "CrabProxyMacApp.throttle.latencyMs.v1",
      "CrabProxyMacApp.throttle.downstreamKbps.v1",
      "CrabProxyMacApp.throttle.upstreamKbps.v1",
      "CrabProxyMacApp.throttle.onlySelectedHosts.v1",
      "CrabProxyMacApp.throttle.selectedHosts.v1",
    ].forEach { defaults.removeObject(forKey: $0) }
  }
}

private enum MockError: LocalizedError {
  case boom

  var errorDescription: String? { "boom" }
}

private final class MockEngineFactory {
  private var engines: [MockProxyEngine]
  private var index = 0

  init(engines: [MockProxyEngine]) {
    self.engines = engines
  }

  func make(listenAddress _: String) throws -> any ProxyEngineControlling {
    guard index < engines.count else {
      throw MockError.boom
    }
    defer { index += 1 }
    return engines[index]
  }
}

private final class MockProxyEngine: ProxyEngineControlling {
  var onLog: (@Sendable (UInt8, String) -> Void)?

  var setListenAddressError: Error?
  var stopError: Error?
  var startError: Error?

  private(set) var calls: [String] = []
  private var running: Bool

  init(running: Bool) {
    self.running = running
  }

  func setListenAddress(_ value: String) throws {
    calls.append("setListenAddress(\(value))")
    if let setListenAddressError { throw setListenAddressError }
  }

  func loadCA(certPath: String, keyPath: String) throws {
    calls.append("loadCA")
  }

  func setInspectEnabled(_ enabled: Bool) throws {
    calls.append("setInspectEnabled(\(enabled))")
  }

  func setThrottleEnabled(_ enabled: Bool) throws {
    calls.append("setThrottleEnabled(\(enabled))")
  }

  func setThrottleLatencyMs(_ latencyMs: UInt64) throws {
    calls.append("setThrottleLatencyMs(\(latencyMs))")
  }

  func setThrottleDownstreamBytesPerSecond(_ bytesPerSecond: UInt64) throws {
    calls.append("setThrottleDownstreamBytesPerSecond(\(bytesPerSecond))")
  }

  func setThrottleUpstreamBytesPerSecond(_ bytesPerSecond: UInt64) throws {
    calls.append("setThrottleUpstreamBytesPerSecond(\(bytesPerSecond))")
  }

  func setThrottleOnlySelectedHosts(_ enabled: Bool) throws {
    calls.append("setThrottleOnlySelectedHosts(\(enabled))")
  }

  func clearThrottleSelectedHosts() throws {
    calls.append("clearThrottleSelectedHosts")
  }

  func addThrottleSelectedHost(_ matcher: String) throws {
    calls.append("addThrottleSelectedHost(\(matcher))")
  }

  func setClientAllowlistEnabled(_ enabled: Bool) throws {
    calls.append("setClientAllowlistEnabled(\(enabled))")
  }

  func clearClientAllowlist() throws {
    calls.append("clearClientAllowlist")
  }

  func addClientAllowlistIP(_ ipAddress: String) throws {
    calls.append("addClientAllowlistIP(\(ipAddress))")
  }

  func setTransparentEnabled(_ enabled: Bool) throws {
    calls.append("setTransparentEnabled(\(enabled))")
  }

  func setTransparentPort(_ port: UInt16) throws {
    calls.append("setTransparentPort(\(port))")
  }

  func clearRules() throws {
    calls.append("clearRules")
  }

  func clearDaemonLogs() throws {
    calls.append("clearDaemonLogs")
  }

  func addAllowRule(_ matcher: String) throws {
    calls.append("addAllowRule(\(matcher))")
  }

  func addMapLocalRule(_ rule: MapLocalRuleConfig) throws {
    calls.append("addMapLocalRule(\(rule.matcher))")
  }

  func addMapRemoteRule(_ rule: MapRemoteRuleConfig) throws {
    calls.append("addMapRemoteRule(\(rule.matcher))")
  }

  func addStatusRewriteRule(_ rule: StatusRewriteRuleConfig) throws {
    calls.append("addStatusRewriteRule(\(rule.matcher))")
  }

  func dumpRules() throws -> RuntimeRulesDump {
    calls.append("dumpRules")
    return RuntimeRulesDump(allowlist: [], mapLocal: [], mapRemote: [], statusRewrite: [])
  }

  func start() throws {
    calls.append("start")
    if let startError { throw startError }
    running = true
  }

  func stop() throws {
    calls.append("stop")
    if let stopError { throw stopError }
    running = false
  }

  func shutdownDaemon() throws {
    calls.append("shutdownDaemon")
  }

  func isRunning() -> Bool {
    calls.append("isRunning")
    return running
  }
}

private final class MockMacSystemProxyService: MacSystemProxyServicing, @unchecked Sendable {
  private let lock = NSLock()
  private var status: MacSystemProxyStatus

  private(set) var readStatusCallCount = 0
  private(set) var disableCallCount = 0

  init(initialStatus: MacSystemProxyStatus) {
    status = initialStatus
  }

  func readStatus() throws -> MacSystemProxyStatus {
    lock.lock()
    defer { lock.unlock() }
    readStatusCallCount += 1
    return status
  }

  func enable(host: String, port: Int) throws -> MacSystemProxyStatus {
    lock.lock()
    defer { lock.unlock() }
    status = .enabled(host: host, port: port)
    return status
  }

  func disable() throws -> MacSystemProxyStatus {
    lock.lock()
    defer { lock.unlock() }
    disableCallCount += 1
    status = .disabled
    return status
  }
}

private struct NoopPFService: PFServicing {
  func enable(proxyPort _: Int, certInstallPath _: String?) async throws {}
  func disable() async throws {}
}

private struct NoopCACertService: CACertServicing {
  func installToSystemKeychain(certPath _: String) async throws {}
  func removeFromSystemKeychain(commonName _: String) async throws {}
  func isInstalledInSystemKeychain(commonName _: String) async -> Bool { false }
}

private extension MacSystemProxyStatus {
  static let disabled = MacSystemProxyStatus(
    networkService: "Wi-Fi",
    interfaceName: "en0",
    webEnabled: false,
    webServer: "",
    webPort: 0,
    secureWebEnabled: false,
    secureWebServer: "",
    secureWebPort: 0
  )

  static func enabled(host: String, port: Int) -> MacSystemProxyStatus {
    MacSystemProxyStatus(
      networkService: "Wi-Fi",
      interfaceName: "en0",
      webEnabled: true,
      webServer: host,
      webPort: port,
      secureWebEnabled: true,
      secureWebServer: host,
      secureWebPort: port
    )
  }
}
