import Foundation

enum ProxyRuntimeCoordinatorError: LocalizedError {
  case engineNotInitialized

  var errorDescription: String? {
    switch self {
    case .engineNotInitialized:
      return "Engine not initialized"
    }
  }
}

final class ProxyRuntimeCoordinator {
  enum Mode {
    case capture
    case bypass

    var capturesTraffic: Bool {
      switch self {
      case .capture:
        true
      case .bypass:
        false
      }
    }
  }

  struct ReconfigureContext {
    let runtimeWasRunning: Bool
    let captureWasEnabled: Bool
  }

  typealias EngineFactory = (String) throws -> any ProxyEngineControlling
  typealias LogHandler = @Sendable (UInt8, String) -> Void
  typealias Configurator = (any ProxyEngineControlling, Mode) throws -> Void

  private let engineFactory: EngineFactory
  var onLog: LogHandler?

  private(set) var engine: (any ProxyEngineControlling)?

  init(engineFactory: @escaping EngineFactory) {
    self.engineFactory = engineFactory
  }

  func initializeEngine(listenAddress: String) throws {
    engine = try makeEngine(listenAddress: listenAddress)
  }

  func transitionRuntime(
    to mode: Mode,
    listenAddress: String,
    configure: Configurator
  ) throws {
    guard let engine else {
      throw ProxyRuntimeCoordinatorError.engineNotInitialized
    }
    if engine.isProxyRunning() {
      try stopRuntimeForReconfigure(listenAddress: listenAddress)
    }
    try startRuntime(mode: mode, listenAddress: listenAddress, configure: configure)
  }

  func prepareForReconfigure(captureEnabled: Bool, listenAddress: String) throws -> ReconfigureContext {
    let runtimeWasRunning = engine?.isProxyRunning() ?? false
    if runtimeWasRunning {
      try stopRuntimeForReconfigure(listenAddress: listenAddress)
    }
    return ReconfigureContext(
      runtimeWasRunning: runtimeWasRunning,
      captureWasEnabled: captureEnabled
    )
  }

  func restoreAfterReconfigureIfNeeded(
    _ context: ReconfigureContext,
    listenAddress: String,
    configure: Configurator
  ) throws {
    guard context.runtimeWasRunning else { return }
    let mode: Mode = context.captureWasEnabled ? .capture : .bypass
    try startRuntime(mode: mode, listenAddress: listenAddress, configure: configure)
  }

  func stopRuntimeForReconfigure(listenAddress: String) throws {
    guard let engine else {
      throw ProxyRuntimeCoordinatorError.engineNotInitialized
    }
    if engine.isProxyRunning() {
      try engine.stopProxyRuntime()
    }
    self.engine = try makeEngine(listenAddress: listenAddress)
  }

  private func startRuntime(
    mode: Mode,
    listenAddress: String,
    configure: Configurator
  ) throws {
    guard let engine else {
      throw ProxyRuntimeCoordinatorError.engineNotInitialized
    }

    try engine.setListenAddress(listenAddress)
    try configure(engine, mode)
    try engine.startProxyRuntime()
    if mode.capturesTraffic {
      try engine.startCaptureRecording()
    } else {
      try engine.stopCaptureRecording()
    }
  }

  private func makeEngine(listenAddress: String) throws -> any ProxyEngineControlling {
    let engine = try engineFactory(listenAddress)
    engine.onLog = onLog
    return engine
  }
}
