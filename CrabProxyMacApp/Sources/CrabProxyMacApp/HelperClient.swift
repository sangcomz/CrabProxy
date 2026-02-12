import Foundation

enum HelperClientError: LocalizedError, Sendable {
  case connectionFailed
  case remoteError(String)

  var errorDescription: String? {
    switch self {
    case .connectionFailed:
      return "Failed to connect to helper daemon"
    case .remoteError(let message):
      return message
    }
  }
}

final class HelperClient: @unchecked Sendable {
  static let machServiceName = "com.sangcomz.CrabProxyHelper"

  private func withProxy<T: Sendable>(
    _ body: @escaping @Sendable (CrabProxyHelperProtocol) -> T
  ) async throws -> T {
    let name = Self.machServiceName
    return try await withCheckedThrowingContinuation { continuation in
      let connection = NSXPCConnection(machServiceName: name, options: .privileged)
      connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)
      connection.invalidationHandler = {
        continuation.resume(throwing: HelperClientError.connectionFailed)
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          continuation.resume(throwing: HelperClientError.remoteError(error.localizedDescription))
          connection.invalidate()
        }) as? CrabProxyHelperProtocol
      else {
        continuation.resume(throwing: HelperClientError.connectionFailed)
        connection.invalidate()
        return
      }

      let result = body(proxy)
      // Invalidate after obtaining result to avoid leaking connections.
      // Note: for async replies, the caller must invalidate after the reply.
      continuation.resume(returning: result)
      connection.invalidate()
    }
  }

  func enablePF(pfConf: String, certPath: String?) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
      connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)

      var resumed = false
      let resume: (Result<Void, Error>) -> Void = { result in
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
        connection.invalidate()
      }

      connection.invalidationHandler = {
        resume(.failure(HelperClientError.connectionFailed))
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          resume(.failure(HelperClientError.remoteError(error.localizedDescription)))
        }) as? CrabProxyHelperProtocol
      else {
        resume(.failure(HelperClientError.connectionFailed))
        return
      }

      proxy.enablePF(pfConf: pfConf, certPath: certPath ?? "") { success, errorMessage in
        if success {
          resume(.success(()))
        } else {
          resume(.failure(HelperClientError.remoteError(errorMessage ?? "Unknown error")))
        }
      }
    }
  }

  func disablePF() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
      connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)

      var resumed = false
      let resume: (Result<Void, Error>) -> Void = { result in
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
        connection.invalidate()
      }

      connection.invalidationHandler = {
        resume(.failure(HelperClientError.connectionFailed))
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          resume(.failure(HelperClientError.remoteError(error.localizedDescription)))
        }) as? CrabProxyHelperProtocol
      else {
        resume(.failure(HelperClientError.connectionFailed))
        return
      }

      proxy.disablePF { success, errorMessage in
        if success {
          resume(.success(()))
        } else {
          resume(.failure(HelperClientError.remoteError(errorMessage ?? "Unknown error")))
        }
      }
    }
  }

  func installCert(certPath: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
      connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)

      var resumed = false
      let resume: (Result<Void, Error>) -> Void = { result in
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
        connection.invalidate()
      }

      connection.invalidationHandler = {
        resume(.failure(HelperClientError.connectionFailed))
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          resume(.failure(HelperClientError.remoteError(error.localizedDescription)))
        }) as? CrabProxyHelperProtocol
      else {
        resume(.failure(HelperClientError.connectionFailed))
        return
      }

      proxy.installCert(certPath: certPath) { success, errorMessage in
        if success {
          resume(.success(()))
        } else {
          resume(.failure(HelperClientError.remoteError(errorMessage ?? "Unknown error")))
        }
      }
    }
  }

  func removeCert(commonName: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
      connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)

      var resumed = false
      let resume: (Result<Void, Error>) -> Void = { result in
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
        connection.invalidate()
      }

      connection.invalidationHandler = {
        resume(.failure(HelperClientError.connectionFailed))
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          resume(.failure(HelperClientError.remoteError(error.localizedDescription)))
        }) as? CrabProxyHelperProtocol
      else {
        resume(.failure(HelperClientError.connectionFailed))
        return
      }

      proxy.removeCert(commonName: commonName) { success, errorMessage in
        if success {
          resume(.success(()))
        } else {
          resume(.failure(HelperClientError.remoteError(errorMessage ?? "Unknown error")))
        }
      }
    }
  }

  func checkCert(commonName: String) async -> Bool {
    do {
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
        let connection = NSXPCConnection(
          machServiceName: Self.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)

        var resumed = false
        let resume: (Result<Bool, Error>) -> Void = { result in
          guard !resumed else { return }
          resumed = true
          continuation.resume(with: result)
          connection.invalidate()
        }

        connection.invalidationHandler = {
          resume(.failure(HelperClientError.connectionFailed))
        }
        connection.resume()

        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            resume(.failure(HelperClientError.remoteError(error.localizedDescription)))
          }) as? CrabProxyHelperProtocol
        else {
          resume(.failure(HelperClientError.connectionFailed))
          return
        }

        proxy.checkCert(commonName: commonName) { found in
          resume(.success(found))
        }
      }
    } catch {
      return false
    }
  }

  func isAvailable() async -> Bool {
    do {
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
        let connection = NSXPCConnection(
          machServiceName: Self.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CrabProxyHelperProtocol.self)

        var resumed = false
        let resume: (Result<Bool, Error>) -> Void = { result in
          guard !resumed else { return }
          resumed = true
          continuation.resume(with: result)
          connection.invalidate()
        }

        connection.invalidationHandler = {
          resume(.success(false))
        }
        connection.resume()

        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            resume(.success(false))
          }) as? CrabProxyHelperProtocol
        else {
          resume(.success(false))
          return
        }

        // Use checkCert as a lightweight ping
        proxy.checkCert(commonName: "__ping__") { _ in
          resume(.success(true))
        }
      }
    } catch {
      return false
    }
  }
}
