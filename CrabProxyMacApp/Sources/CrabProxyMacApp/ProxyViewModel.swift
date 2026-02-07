import Combine
import Foundation
import Darwin

struct ProxyLogEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: UInt8
    let levelLabel: String
    let event: String
    let method: String
    let url: String
    let statusCode: String?
    let peer: String?
    let mapLocalMatcher: String?
    var requestHeaders: String?
    var responseHeaders: String?
    var requestBodyPreview: String?
    var responseBodyPreview: String?
    let rawLine: String
}

enum RuleSourceType: String, CaseIterable, Identifiable {
    case file = "File"
    case text = "Text"

    var id: String { rawValue }
}

struct MapLocalRuleInput: Identifiable, Hashable {
    let id: UUID
    var matcher: String
    var sourceType: RuleSourceType
    var sourceValue: String
    var statusCode: String
    var contentType: String

    init(
        id: UUID = UUID(),
        matcher: String = "",
        sourceType: RuleSourceType = .file,
        sourceValue: String = "",
        statusCode: String = "200",
        contentType: String = ""
    ) {
        self.id = id
        self.matcher = matcher
        self.sourceType = sourceType
        self.sourceValue = sourceValue
        self.statusCode = statusCode
        self.contentType = contentType
    }
}

struct StatusRewriteRuleInput: Identifiable, Hashable {
    let id: UUID
    var matcher: String
    var fromStatusCode: String
    var toStatusCode: String

    init(
        id: UUID = UUID(),
        matcher: String = "",
        fromStatusCode: String = "",
        toStatusCode: String = "200"
    ) {
        self.id = id
        self.matcher = matcher
        self.fromStatusCode = fromStatusCode
        self.toStatusCode = toStatusCode
    }
}

struct AllowRuleInput: Identifiable, Hashable {
    let id: UUID
    var matcher: String

    init(id: UUID = UUID(), matcher: String = "") {
        self.id = id
        self.matcher = matcher
    }
}

private enum ProxyValidationError: Error, LocalizedError {
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case let .invalidValue(message):
            return message
        }
    }
}

private struct PendingTransactionMeta {
    var requestHeaders: String?
    var responseHeaders: String?
    var requestBodyPreview: String?
    var responseBodyPreview: String?

    init(
        requestHeaders: String? = nil,
        responseHeaders: String? = nil,
        requestBodyPreview: String? = nil,
        responseBodyPreview: String? = nil
    ) {
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBodyPreview = requestBodyPreview
        self.responseBodyPreview = responseBodyPreview
    }

    var isEmpty: Bool {
        requestHeaders == nil
            && responseHeaders == nil
            && requestBodyPreview == nil
            && responseBodyPreview == nil
    }

    mutating func merge(_ other: PendingTransactionMeta) {
        if let value = other.requestHeaders { requestHeaders = value }
        if let value = other.responseHeaders { responseHeaders = value }
        if let value = other.requestBodyPreview { requestBodyPreview = value }
        if let value = other.responseBodyPreview { responseBodyPreview = value }
    }
}

@MainActor
final class ProxyViewModel: ObservableObject {
    let certPortalURL = "http://crab-proxy.local/"
    let listenAddress = "0.0.0.0:8888"
    @Published private(set) var caCertPath = ""
    @Published private(set) var caStatusText = "Preparing internal CA"
    @Published var inspectBodies = true
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var visibleURLFilter = ""
    @Published private(set) var macSystemProxyEnabled = false
    @Published private(set) var macSystemProxyServiceText = "Unknown"
    @Published private(set) var macSystemProxyStateText = "Unknown"
    @Published private(set) var isApplyingMacSystemProxy = false
    @Published private(set) var logs: [ProxyLogEntry] = []
    @Published var selectedLogID: ProxyLogEntry.ID?
    @Published var allowRules: [AllowRuleInput] = []
    @Published var mapLocalRules: [MapLocalRuleInput] = []
    @Published var statusRewriteRules: [StatusRewriteRuleInput] = []

    private var engine: RustProxyEngine?
    private var pendingMetaByKey: [String: PendingTransactionMeta] = [:]
    private var latestLogIDByKey: [String: UUID] = [:]
    private static let maxLogEntries = 800
    private static let allowRulesDefaultsKey = "CrabProxyMacApp.allowRules"
    private static let defaultAllowRuleMatcher = "*.*"
    private let internalCACommonName = "Crab Proxy Internal Root CA"
    private let internalCADays: UInt32 = 3650
    private var cancellables: Set<AnyCancellable> = []

    init() {
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
    }

    var filteredLogs: [ProxyLogEntry] {
        let ordered = logs.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }

        let needle = trimmed(visibleURLFilter)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { entry in
            entry.url.localizedCaseInsensitiveContains(needle)
                || entry.rawLine.localizedCaseInsensitiveContains(needle)
        }
    }

    var selectedLog: ProxyLogEntry? {
        guard let selectedLogID else { return nil }
        return logs.first(where: { $0.id == selectedLogID })
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
        logs.removeAll(keepingCapacity: true)
        selectedLogID = nil
        pendingMetaByKey.removeAll(keepingCapacity: true)
        latestLogIDByKey.removeAll(keepingCapacity: true)
    }

    var macSystemProxyTarget: String {
        "127.0.0.1:\(parsedListen.port)"
    }

    func refreshMacSystemProxyStatus(autoEnableIfDisabled: Bool = false) {
        Task {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try MacSystemProxyService.readStatus()
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
        isApplyingMacSystemProxy = true

        Task {
            defer { isApplyingMacSystemProxy = false }
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try MacSystemProxyService.enable(host: "127.0.0.1", port: port)
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
        isApplyingMacSystemProxy = true

        Task {
            defer { isApplyingMacSystemProxy = false }
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try MacSystemProxyService.disable()
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
        try engine.clearRules()

        for matcher in normalizedAllowMatchers() {
            try engine.addAllowRule(matcher)
        }

        for (index, draft) in mapLocalRules.enumerated() {
            let matcher = trimmed(draft.matcher)
            let sourceValue = trimmed(draft.sourceValue)
            let contentType = optionalTrimmed(draft.contentType)
            let status = try parseStatusCode(
                draft.statusCode,
                defaultValue: 200,
                field: "Map Local #\(index + 1) status"
            )

            if matcher.isEmpty && sourceValue.isEmpty && contentType == nil {
                continue
            }
            guard !matcher.isEmpty else {
                throw ProxyValidationError.invalidValue(
                    "Map Local #\(index + 1): matcher is required"
                )
            }
            guard !sourceValue.isEmpty else {
                throw ProxyValidationError.invalidValue(
                    "Map Local #\(index + 1): source value is required"
                )
            }

            let source: MapLocalSource
            switch draft.sourceType {
            case .file:
                source = .file(path: sourceValue)
            case .text:
                source = .text(value: sourceValue)
            }

            try engine.addMapLocalRule(
                MapLocalRuleConfig(
                    matcher: matcher,
                    source: source,
                    statusCode: status,
                    contentType: contentType
                )
            )
        }

        for (index, draft) in statusRewriteRules.enumerated() {
            let matcher = trimmed(draft.matcher)
            let fromStatus = try parseOptionalStatusCode(
                draft.fromStatusCode,
                field: "Status Rewrite #\(index + 1) from"
            )
            let toStatus = try parseStatusCode(
                draft.toStatusCode,
                defaultValue: nil,
                field: "Status Rewrite #\(index + 1) to"
            )

            if matcher.isEmpty && fromStatus == nil && trimmed(draft.toStatusCode).isEmpty {
                continue
            }
            guard !matcher.isEmpty else {
                throw ProxyValidationError.invalidValue(
                    "Status Rewrite #\(index + 1): matcher is required"
                )
            }

            try engine.addStatusRewriteRule(
                StatusRewriteRuleConfig(
                    matcher: matcher,
                    fromStatusCode: fromStatus,
                    toStatusCode: toStatus
                )
            )
        }
    }

    private func parseStatusCode(
        _ input: String,
        defaultValue: UInt16?,
        field: String
    ) throws -> UInt16 {
        let value = trimmed(input)
        if value.isEmpty {
            if let defaultValue {
                return defaultValue
            }
            throw ProxyValidationError.invalidValue("\(field) is required")
        }
        guard let code = UInt16(value), (100...599).contains(code) else {
            throw ProxyValidationError.invalidValue("\(field) must be a valid HTTP status (100-599)")
        }
        return code
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
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("CrabProxyMacApp", isDirectory: true)
            .appendingPathComponent("ca", isDirectory: true)
        return (
            cert: dir.appendingPathComponent("ca.crt.pem"),
            key: dir.appendingPathComponent("ca.key.pem")
        )
    }

    private func internalCAURLs() throws -> (cert: URL, key: URL) {
        guard let urls = internalCAURLsIfAvailable() else {
            throw ProxyValidationError.invalidValue("Could not access Application Support directory")
        }
        try FileManager.default.createDirectory(
            at: urls.cert.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return urls
    }

    private func parseOptionalStatusCode(_ input: String, field: String) throws -> Int? {
        let value = trimmed(input)
        if value.isEmpty {
            return nil
        }
        guard let code = Int(value), (100...599).contains(code) else {
            throw ProxyValidationError.invalidValue("\(field) must be empty or a valid HTTP status (100-599)")
        }
        return code
    }

    private func parseListenAddress() -> (host: String, port: UInt16) {
        let raw = trimmed(listenAddress)
        guard !raw.isEmpty else {
            return ("127.0.0.1", 8888)
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
        struct Candidate {
            let name: String
            let ip: String
            let priority: Int
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(first) }

        var candidates: [Candidate] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }
            guard let addr = ptr.pointee.ifa_addr else { continue }
            guard let cName = ptr.pointee.ifa_name else { continue }

            if addr.pointee.sa_family != UInt8(AF_INET) {
                continue
            }

            let flags = Int32(ptr.pointee.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_RUNNING) == 0 || (flags & IFF_LOOPBACK) != 0 {
                continue
            }

            let name = String(cString: cName)
            if shouldIgnoreForProxy(name) {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddr = addr.pointee
            let result = getnameinfo(
                &socketAddr,
                socklen_t(socketAddr.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result != 0 {
                continue
            }

            let ip = hostname.withUnsafeBufferPointer { buffer -> String in
                guard let base = buffer.baseAddress else { return "" }
                return String(validatingCString: base) ?? ""
            }
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") {
                continue
            }
            candidates.append(
                Candidate(
                    name: name,
                    ip: ip,
                    priority: interfacePriority(name)
                )
            )
        }

        return candidates
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority < $1.priority
                }
                if $0.name != $1.name {
                    return $0.name < $1.name
                }
                return $0.ip < $1.ip
            }
            .first?
            .ip
    }

    private func shouldIgnoreForProxy(_ interfaceName: String) -> Bool {
        let value = interfaceName.lowercased()
        let ignoredPrefixes = [
            "lo", "utun", "awdl", "llw", "bridge", "vmnet", "vboxnet", "docker", "tap", "tun",
        ]
        return ignoredPrefixes.contains { value.hasPrefix($0) }
    }

    private func interfacePriority(_ interfaceName: String) -> Int {
        let value = interfaceName.lowercased()
        if value == "en0" { return 0 }
        if value == "en1" { return 1 }
        if value == "en2" { return 2 }
        if value.hasPrefix("en") { return 10 }
        return 50
    }

    private func appendLog(level: UInt8, message: String) {
        guard let entry = makeEntry(level: level, line: message) else { return }

        let key = transactionKey(peer: entry.peer, method: entry.method, url: entry.url)
        var materialized = entry
        if let pending = pendingMetaByKey.removeValue(forKey: key) {
            apply(meta: pending, to: &materialized)
        }

        logs.append(materialized)
        latestLogIDByKey[key] = materialized.id

        if logs.count > Self.maxLogEntries {
            let overflow = logs.count - Self.maxLogEntries
            let removedIDs = Set(logs.prefix(overflow).map(\.id))
            logs.removeFirst(overflow)
            latestLogIDByKey = latestLogIDByKey.filter { !removedIDs.contains($0.value) }
        }

        if selectedLogID == nil || logs.contains(where: { $0.id == selectedLogID }) == false {
            selectedLogID = logs.last?.id
        }
    }

    private func makeEntry(level: UInt8, line: String) -> ProxyLogEntry? {
        let trimmedLine = trimmed(line)
        guard !trimmedLine.isEmpty else { return nil }

        if handleMetadataLog(trimmedLine) {
            return nil
        }

        if trimmedLine.contains("proxy listening")
            || trimmedLine.contains("shutdown signal received")
            || trimmedLine.contains("shutdown channel closed")
            || trimmedLine.contains("CONNECT")
            || trimmedLine.contains("request failed")
        {
            return nil
        }

        let event: String
        if trimmedLine.contains("cert_portal") {
            event = "cert_portal"
        } else if trimmedLine.contains("map_local") {
            event = "map_local"
        } else if trimmedLine.contains("upstream") {
            event = "upstream"
        } else {
            return nil
        }

        guard let url = Self.firstCapture(Self.urlRegex, in: trimmedLine) else {
            return nil
        }

        let method = Self.firstCapture(Self.methodRegex, in: trimmedLine) ?? "HTTP"
        let statusCode = Self.firstCapture(Self.statusRegex, in: trimmedLine)
            ?? Self.firstCapture(Self.responseStatusRegex, in: trimmedLine)
        let peer = Self.firstCapture(Self.peerRegex, in: trimmedLine)
        let mapLocal = Self.firstCapture(Self.mapLocalRegex, in: trimmedLine)

        return ProxyLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            levelLabel: levelLabel(for: level),
            event: event,
            method: method,
            url: url,
            statusCode: statusCode,
            peer: peer,
            mapLocalMatcher: mapLocal,
            requestHeaders: nil,
            responseHeaders: nil,
            requestBodyPreview: nil,
            responseBodyPreview: nil,
            rawLine: trimmedLine
        )
    }

    private func handleMetadataLog(_ line: String) -> Bool {
        if line.contains("request_headers") {
            guard
                let peer = Self.firstCapture(Self.peerRegex, in: line),
                let method = Self.firstCapture(Self.methodRegex, in: line),
                let url = Self.firstCapture(Self.urlRegex, in: line),
                let headersB64 = Self.firstCapture(Self.headersB64Regex, in: line)
            else {
                return true
            }
            let decoded = decodeBase64Text(headersB64) ?? "<failed to decode headers>"
            let key = transactionKey(peer: peer, method: method, url: url)
            applyMetadata(PendingTransactionMeta(requestHeaders: decoded), toKey: key)
            return true
        }

        if line.contains("response_headers") {
            guard
                let peer = Self.firstCapture(Self.peerRegex, in: line),
                let method = Self.firstCapture(Self.methodRegex, in: line),
                let url = Self.firstCapture(Self.urlRegex, in: line),
                let headersB64 = Self.firstCapture(Self.headersB64Regex, in: line)
            else {
                return true
            }
            let decoded = decodeBase64Text(headersB64) ?? "<failed to decode headers>"
            let key = transactionKey(peer: peer, method: method, url: url)
            applyMetadata(PendingTransactionMeta(responseHeaders: decoded), toKey: key)
            return true
        }

        if line.contains("body inspection") {
            guard
                let peer = Self.firstCapture(Self.peerRegex, in: line),
                let method = Self.firstCapture(Self.methodRegex, in: line),
                let url = Self.firstCapture(Self.urlRegex, in: line),
                let direction = Self.firstCapture(Self.directionRegex, in: line),
                let sampleB64 = Self.firstCapture(Self.sampleB64Regex, in: line)
            else {
                return true
            }
            let preview = decodeBodyPreview(sampleB64)
            let key = transactionKey(peer: peer, method: method, url: url)
            if direction == "request" {
                applyMetadata(PendingTransactionMeta(requestBodyPreview: preview), toKey: key)
            } else if direction == "response" {
                applyMetadata(PendingTransactionMeta(responseBodyPreview: preview), toKey: key)
            }
            return true
        }

        return false
    }

    private func transactionKey(peer: String?, method: String, url: String) -> String {
        "\(peer ?? "-")|\(method)|\(url)"
    }

    private func applyMetadata(_ meta: PendingTransactionMeta, toKey key: String) {
        guard !meta.isEmpty else { return }

        if let entryID = latestLogIDByKey[key], let index = logs.firstIndex(where: { $0.id == entryID }) {
            var entry = logs[index]
            apply(meta: meta, to: &entry)
            logs[index] = entry
            return
        }

        var pending = pendingMetaByKey[key] ?? PendingTransactionMeta()
        pending.merge(meta)
        pendingMetaByKey[key] = pending
    }

    private func apply(meta: PendingTransactionMeta, to entry: inout ProxyLogEntry) {
        if let value = meta.requestHeaders { entry.requestHeaders = value }
        if let value = meta.responseHeaders { entry.responseHeaders = value }
        if let value = meta.requestBodyPreview { entry.requestBodyPreview = value }
        if let value = meta.responseBodyPreview { entry.responseBodyPreview = value }
    }

    private func decodeBase64Text(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeBodyPreview(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value), !data.isEmpty else { return nil }
        return prettyBodyText(from: data)
    }

    private func prettyBodyText(from data: Data) -> String {
        if let prettyJSON = prettyJSONString(from: data) {
            return prettyJSON
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        let bytes = Array(data.prefix(256))
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "<binary \(data.count) bytes>\n\(hex)"
    }

    private func prettyJSONString(from data: Data) -> String? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(jsonObject) else { return nil }
        guard let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: prettyData, encoding: .utf8)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmed = trimmed(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func levelLabel(for level: UInt8) -> String {
        switch level {
        case 4:
            return "ERROR"
        case 3:
            return "WARN"
        case 1:
            return "DEBUG"
        case 0:
            return "TRACE"
        default:
            return "INFO"
        }
    }

    private static let urlRegex = try! NSRegularExpression(pattern: #"url=([^\s]+)"#)
    private static let methodRegex = try! NSRegularExpression(pattern: #"method=([A-Z]+)"#)
    private static let statusRegex = try! NSRegularExpression(pattern: #"status=([0-9]{3})"#)
    private static let responseStatusRegex = try! NSRegularExpression(
        pattern: #"response_status=Some\(([0-9]{3})(?:[^\)]*)\)"#
    )
    private static let peerRegex = try! NSRegularExpression(pattern: #"peer=([^\s]+)"#)
    private static let mapLocalRegex = try! NSRegularExpression(pattern: #"map_local=([^\s]+)"#)
    private static let headersB64Regex = try! NSRegularExpression(pattern: #"headers_b64=([A-Za-z0-9+/=]+)"#)
    private static let sampleB64Regex = try! NSRegularExpression(pattern: #"sample_b64=([A-Za-z0-9+/=]+)"#)
    private static let directionRegex = try! NSRegularExpression(pattern: #"direction=([a-z]+)"#)

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1
        else { return nil }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private func bindPersistence() {
        $allowRules
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistAllowRules()
            }
            .store(in: &cancellables)
    }

    private func normalizedAllowMatchers() -> [String] {
        var seen: Set<String> = []
        var values: [String] = []

        for draft in allowRules {
            let matcher = trimmed(draft.matcher)
            if matcher.isEmpty {
                continue
            }
            let key = matcher.lowercased()
            if seen.insert(key).inserted {
                values.append(matcher)
            }
        }
        return values
    }

    private func persistAllowRules() {
        let values = normalizedAllowMatchers()
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
