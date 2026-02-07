#if canImport(CCrabMitm)
import CCrabMitm
#endif
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

struct StatusRewriteRuleConfig {
    var matcher: String
    var fromStatusCode: Int?
    var toStatusCode: UInt16
}

final class RustProxyEngine {
    private var handle: OpaquePointer?
    var onLog: (@Sendable (UInt8, String) -> Void)?

    init(listenAddress: String) throws {
        var raw: OpaquePointer?
        let result = listenAddress.withCString { crab_proxy_create(&raw, $0) }
        try Self.check(result)

        guard let raw else {
            throw RustProxyError.internalState("failed to create proxy handle")
        }
        handle = raw

        crab_set_log_callback(rustLogCallbackBridge, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        crab_set_log_callback(nil, nil)
        if let h = handle {
            _ = crab_proxy_stop(h)
            crab_proxy_destroy(h)
        }
    }

    func setListenAddress(_ value: String) throws {
        let h = try requireHandle()
        let result = value.withCString { crab_proxy_set_listen_addr(h, $0) }
        try Self.check(result)
    }

    func setPort(_ value: UInt16) throws {
        let h = try requireHandle()
        let result = crab_proxy_set_port(h, value)
        try Self.check(result)
    }

    func loadCA(certPath: String, keyPath: String) throws {
        let h = try requireHandle()
        let result = certPath.withCString { cert in
            keyPath.withCString { key in
                crab_proxy_load_ca(h, cert, key)
            }
        }
        try Self.check(result)
    }

    static func generateCA(commonName: String, days: UInt32, certPath: String, keyPath: String) throws {
        let result = commonName.withCString { cn in
            certPath.withCString { cert in
                keyPath.withCString { key in
                    crab_ca_generate(cn, days, cert, key)
                }
            }
        }
        try Self.check(result)
    }

    func setInspectEnabled(_ enabled: Bool) throws {
        let h = try requireHandle()
        let result = crab_proxy_set_inspect_enabled(h, enabled)
        try Self.check(result)
    }

    func clearRules() throws {
        let h = try requireHandle()
        try Self.check(crab_proxy_rules_clear(h))
    }

    func addAllowRule(_ matcher: String) throws {
        let h = try requireHandle()
        let normalized = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw RustProxyError.internalState("allow matcher must not be empty")
        }
        let result = normalized.withCString {
            crab_proxy_rules_add_allow(h, $0)
        }
        try Self.check(result)
    }

    func addMapLocalRule(_ rule: MapLocalRuleConfig) throws {
        let h = try requireHandle()
        try rule.matcher.withCString { matcher in
            let contentType = rule.contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContentType = (contentType?.isEmpty == true) ? nil : contentType
            try withOptionalCString(normalizedContentType) { contentTypePtr in
                let result: CrabResult
                switch rule.source {
                case let .file(path):
                    result = path.withCString { filePath in
                        crab_proxy_rules_add_map_local_file(
                            h,
                            matcher,
                            filePath,
                            rule.statusCode,
                            contentTypePtr
                        )
                    }
                case let .text(value):
                    result = value.withCString { text in
                        crab_proxy_rules_add_map_local_text(
                            h,
                            matcher,
                            text,
                            rule.statusCode,
                            contentTypePtr
                        )
                    }
                }
                try Self.check(result)
            }
        }
    }

    func addStatusRewriteRule(_ rule: StatusRewriteRuleConfig) throws {
        let h = try requireHandle()
        let fromStatus = Int32(rule.fromStatusCode ?? -1)
        let toStatus = rule.toStatusCode
        let result = rule.matcher.withCString {
            crab_proxy_rules_add_status_rewrite(h, $0, fromStatus, toStatus)
        }
        try Self.check(result)
    }

    func start() throws {
        let h = try requireHandle()
        try Self.check(crab_proxy_start(h))
    }

    func stop() throws {
        let h = try requireHandle()
        try Self.check(crab_proxy_stop(h))
    }

    func isRunning() -> Bool {
        guard let h = handle else { return false }
        return crab_proxy_is_running(h)
    }

    fileprivate func receiveLog(level: UInt8, message: String) {
        onLog?(level, message)
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else {
            throw RustProxyError.internalState("proxy handle is nil")
        }
        return handle
    }

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
}

private func withOptionalCString<T>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> T
) throws -> T {
    if let value {
        return try value.withCString { ptr in
            try body(ptr)
        }
    }
    return try body(nil)
}

private func rustLogCallbackBridge(
    _ userData: UnsafeMutableRawPointer?,
    _ level: UInt8,
    _ message: UnsafePointer<CChar>?
) {
    guard let userData else { return }
    let engine = Unmanaged<RustProxyEngine>.fromOpaque(userData).takeUnretainedValue()
    let text = message.map { String(cString: $0) } ?? ""
    engine.receiveLog(level: level, message: text)
}
