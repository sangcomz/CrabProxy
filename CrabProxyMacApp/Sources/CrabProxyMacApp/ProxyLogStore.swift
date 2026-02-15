import Foundation

enum ClientPlatform: String, Hashable {
    case macOS = "macOS"
    case mobile = "Mobile"
}

struct ProxyLogEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: UInt8
    let levelLabel: String
    let correlationKey: String
    let event: String
    let method: String
    let url: String
    let statusCode: String?
    let peer: String?
    let mapLocalMatcher: String?
    var clientPlatform: ClientPlatform?
    let durationMs: Double?
    var responseSizeBytes: Int64?
    var requestHeaders: String?
    var responseHeaders: String?
    var requestBodyPreview: String?
    var responseBodyPreview: String?
    let rawLine: String
}

private struct PendingTransactionMeta {
    var requestHeaders: String?
    var responseHeaders: String?
    var requestBodyPreview: String?
    var responseBodyPreview: String?
    var responseSizeBytes: Int64?
    var clientPlatform: ClientPlatform?

    var isEmpty: Bool {
        requestHeaders == nil
            && responseHeaders == nil
            && requestBodyPreview == nil
            && responseBodyPreview == nil
            && responseSizeBytes == nil
            && clientPlatform == nil
    }

    mutating func merge(_ other: PendingTransactionMeta) {
        if let value = other.requestHeaders { requestHeaders = value }
        if let value = other.responseHeaders { responseHeaders = value }
        if let value = other.requestBodyPreview { requestBodyPreview = value }
        if let value = other.responseBodyPreview { responseBodyPreview = value }
        if let value = other.responseSizeBytes { responseSizeBytes = value }
        if let value = other.clientPlatform { clientPlatform = value }
    }
}

@MainActor
final class ProxyLogStore {
    private(set) var logs: [ProxyLogEntry] = []
    private var pendingMetaByKey: [String: PendingTransactionMeta] = [:]
    private var latestLogIDByKey: [String: UUID] = [:]
    private var logIndexByID: [UUID: Int] = [:]
    private let maxLogEntries: Int

    init(maxLogEntries: Int) {
        self.maxLogEntries = maxLogEntries
    }

    func clear() -> [ProxyLogEntry] {
        logs.removeAll(keepingCapacity: true)
        pendingMetaByKey.removeAll(keepingCapacity: true)
        latestLogIDByKey.removeAll(keepingCapacity: true)
        logIndexByID.removeAll(keepingCapacity: true)
        return logs
    }

    func selectedLog(id: ProxyLogEntry.ID?) -> ProxyLogEntry? {
        guard let id, let index = logIndexByID[id], logs.indices.contains(index) else { return nil }
        return logs[index]
    }

    func append(level: UInt8, message: String, currentSelectedLogID: ProxyLogEntry.ID?) -> (logs: [ProxyLogEntry], selectedLogID: ProxyLogEntry.ID?)? {
        let trimmedLine = trimmed(message)
        guard !trimmedLine.isEmpty else { return nil }

        if let payload = parseStructuredPayload(level: level, line: trimmedLine) {
            switch payload {
            case let .entry(entry):
                return appendEntry(entry, currentSelectedLogID: currentSelectedLogID)
            case let .metadata(key, meta):
                if applyMetadata(meta, toKey: key) {
                    return (logs, currentSelectedLogID)
                }
                return nil
            case .ignore:
                return nil
            }
        }

        // Prefer structured CRAB_JSON logs to avoid duplicate plain+JSON rows.
        return nil
    }

    func appendBatch(
        _ events: [(level: UInt8, message: String)],
        currentSelectedLogID: ProxyLogEntry.ID?
    ) -> (logs: [ProxyLogEntry], selectedLogID: ProxyLogEntry.ID?)? {
        guard !events.isEmpty else { return nil }

        var selected = currentSelectedLogID
        var didChange = false

        for event in events {
            if let snapshot = append(
                level: event.level,
                message: event.message,
                currentSelectedLogID: selected
            ) {
                selected = snapshot.selectedLogID
                didChange = true
            }
        }

        guard didChange else { return nil }
        return (logs, selected)
    }

    private func rebuildLogIndex() {
        var next: [UUID: Int] = [:]
        next.reserveCapacity(logs.count)
        for (index, entry) in logs.enumerated() {
            next[entry.id] = index
        }
        logIndexByID = next
    }

    private func appendEntry(_ entry: ProxyLogEntry, currentSelectedLogID: ProxyLogEntry.ID?) -> (logs: [ProxyLogEntry], selectedLogID: ProxyLogEntry.ID?) {
        let key = entry.correlationKey
        var materialized = entry
        if let pending = pendingMetaByKey.removeValue(forKey: key) {
            apply(meta: pending, to: &materialized)
        }

        logs.append(materialized)
        latestLogIDByKey[key] = materialized.id
        logIndexByID[materialized.id] = logs.count - 1

        if logs.count > maxLogEntries {
            let overflow = logs.count - maxLogEntries
            let removedIDs = Set(logs.prefix(overflow).map(\.id))
            logs.removeFirst(overflow)
            latestLogIDByKey = latestLogIDByKey.filter { !removedIDs.contains($0.value) }
            rebuildLogIndex()
        }

        let isSelectionValid = currentSelectedLogID.flatMap { logIndexByID[$0] } != nil
        let selectedLogID = (currentSelectedLogID == nil || !isSelectionValid) ? logs.last?.id : currentSelectedLogID
        return (logs, selectedLogID)
    }

    private enum StructuredPayload {
        case entry(ProxyLogEntry)
        case metadata(key: String, meta: PendingTransactionMeta)
        case ignore
    }

    private func parseStructuredPayload(level: UInt8, line: String) -> StructuredPayload? {
        guard let marker = line.range(of: "CRAB_JSON ") else {
            return nil
        }
        let jsonText = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsonText.isEmpty, let data = jsonText.data(using: .utf8) else {
            return .ignore
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignore
        }

        let payloadType = stringField("type", in: object) ?? ""
        let event = stringField("event", in: object) ?? ""

        if payloadType == "entry" {
            guard
                let method = stringField("method", in: object),
                let url = stringField("url", in: object)
            else {
                return .ignore
            }
            let status = statusField(in: object)
            let peer = stringField("peer", in: object)
            let mapLocal = stringField("map_local", in: object)
            let clientPlatform = inferClientPlatform(requestHeaders: nil, peer: peer)
            let durationMs = doubleField("duration_ms", in: object)
            let responseSizeBytes = int64Field("response_size_bytes", in: object)
            let requestID = stringField("request_id", in: object)
            let correlationKey = transactionKey(
                requestID: requestID,
                peer: peer,
                method: method,
                url: url
            )
            return .entry(
                ProxyLogEntry(
                    id: UUID(),
                    timestamp: Date(),
                    level: level,
                    levelLabel: levelLabel(for: level),
                    correlationKey: correlationKey,
                    event: event,
                    method: method,
                    url: url,
                    statusCode: status,
                    peer: peer,
                    mapLocalMatcher: mapLocal,
                    clientPlatform: clientPlatform,
                    durationMs: durationMs,
                    responseSizeBytes: responseSizeBytes,
                    requestHeaders: nil,
                    responseHeaders: nil,
                    requestBodyPreview: nil,
                    responseBodyPreview: nil,
                    rawLine: line
                )
            )
        }

        if payloadType == "meta" {
            guard
                let peer = stringField("peer", in: object),
                let method = stringField("method", in: object),
                let url = stringField("url", in: object)
            else {
                return .ignore
            }
            let requestID = stringField("request_id", in: object)
            let key = transactionKey(
                requestID: requestID,
                peer: peer,
                method: method,
                url: url
            )

            switch event {
            case "request_headers":
                let headersB64 = stringField("headers_b64", in: object) ?? ""
                let decoded = decodeHeaderPreview(headersB64) ?? "<failed to decode headers>"
                let clientPlatform = inferClientPlatform(requestHeaders: decoded, peer: peer)
                return .metadata(
                    key: key,
                    meta: PendingTransactionMeta(
                        requestHeaders: decoded,
                        clientPlatform: clientPlatform
                    )
                )
            case "response_headers":
                let headersB64 = stringField("headers_b64", in: object) ?? ""
                let decoded = decodeHeaderPreview(headersB64) ?? "<failed to decode headers>"
                return .metadata(key: key, meta: PendingTransactionMeta(responseHeaders: decoded))
            case "body_inspection":
                let direction = stringField("direction", in: object) ?? ""
                let sampleB64 = stringField("sample_b64", in: object) ?? ""
                let preview = decodeBodyPreview(sampleB64)
                let bodyBytes = int64Field("body_bytes", in: object)
                if direction == "request" {
                    return .metadata(key: key, meta: PendingTransactionMeta(requestBodyPreview: preview))
                }
                if direction == "response" {
                    return .metadata(
                        key: key,
                        meta: PendingTransactionMeta(
                            responseBodyPreview: preview,
                            responseSizeBytes: bodyBytes
                        )
                    )
                }
                return .ignore
            default:
                return .ignore
            }
        }

        return .ignore
    }

    private func stringField(_ key: String, in object: [String: Any]) -> String? {
        if let value = object[key] as? String {
            return value
        }
        if let number = object[key] as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func doubleField(_ key: String, in object: [String: Any]) -> Double? {
        if let value = object[key] as? NSNumber {
            return value.doubleValue
        }
        if let value = object[key] as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func int64Field(_ key: String, in object: [String: Any]) -> Int64? {
        if let value = object[key] as? NSNumber {
            return value.int64Value
        }
        if let value = object[key] as? String {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func inferClientPlatform(requestHeaders: String?, peer: String?) -> ClientPlatform? {
        if let ua = userAgent(from: requestHeaders) {
            let normalizedUA = ua.lowercased()
            if normalizedUA.contains("iphone")
                || normalizedUA.contains("ipad")
                || normalizedUA.contains("ipod")
                || normalizedUA.contains("android")
                || normalizedUA.contains("mobile")
            {
                return .mobile
            }
            if normalizedUA.contains("macintosh") || normalizedUA.contains("mac os x") {
                return .macOS
            }
        }

        guard let host = hostFromPeer(peer) else { return nil }
        if isLoopbackHost(host) {
            return .macOS
        }
        if isLikelyLANHost(host) {
            return .mobile
        }
        return nil
    }

    private func userAgent(from headers: String?) -> String? {
        guard let headers else { return nil }
        for rawLine in headers.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("User-Agent") == .orderedSame else { continue }
            let valueStart = line.index(after: separator)
            let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func hostFromPeer(_ peer: String?) -> String? {
        guard var peer else { return nil }
        peer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { return nil }

        if peer.hasPrefix("["),
           let closing = peer.firstIndex(of: "]")
        {
            let hostStart = peer.index(after: peer.startIndex)
            return String(peer[hostStart..<closing]).lowercased()
        }

        if let lastColon = peer.lastIndex(of: ":") {
            return String(peer[..<lastColon]).lowercased()
        }

        return peer.lowercased()
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        host == "127.0.0.1"
            || host == "::1"
            || host == "localhost"
    }

    private func isLikelyLANHost(_ host: String) -> Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return true
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        if host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") {
            return true
        }
        return false
    }

    private func statusField(in object: [String: Any]) -> String? {
        if let value = object["status"] as? NSNumber {
            return value.stringValue
        }
        if let value = object["status"] as? String {
            return value
        }
        if let value = object["response_status"] as? NSNumber {
            return value.stringValue
        }
        if let value = object["response_status"] as? String {
            return value
        }
        return nil
    }

    private func makeEntry(level: UInt8, line: String) -> ProxyLogEntry? {
        if line.contains("proxy listening")
            || line.contains("shutdown signal received")
            || line.contains("shutdown channel closed")
            || line.contains("CONNECT")
            || line.contains("request failed")
        {
            return nil
        }

        let event: String
        if line.contains("cert_portal") {
            event = "cert_portal"
        } else if line.contains("map_local") {
            event = "map_local"
        } else if line.contains("upstream") {
            event = "upstream"
        } else {
            return nil
        }

        guard let url = Self.firstCapture(Self.urlRegex, in: line) else {
            return nil
        }

        let method = Self.firstCapture(Self.methodRegex, in: line) ?? "HTTP"
        let statusCode = Self.firstCapture(Self.statusRegex, in: line)
            ?? Self.firstCapture(Self.responseStatusRegex, in: line)
        let peer = Self.firstCapture(Self.peerRegex, in: line)
        let clientPlatform = inferClientPlatform(requestHeaders: nil, peer: peer)
        let requestID = Self.firstCapture(Self.requestIDRegex, in: line)
        let mapLocal = Self.firstCapture(Self.mapLocalRegex, in: line)

        return ProxyLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            levelLabel: levelLabel(for: level),
            correlationKey: transactionKey(requestID: requestID, peer: peer, method: method, url: url),
            event: event,
            method: method,
            url: url,
            statusCode: statusCode,
            peer: peer,
            mapLocalMatcher: mapLocal,
            clientPlatform: clientPlatform,
            durationMs: nil,
            responseSizeBytes: nil,
            requestHeaders: nil,
            responseHeaders: nil,
            requestBodyPreview: nil,
            responseBodyPreview: nil,
            rawLine: line
        )
    }

    // Returns nil when line is not metadata.
    // Returns false when line is metadata but no visible log row changed.
    // Returns true when line is metadata and an existing visible log row changed.
    private func handleMetadataLog(_ line: String) -> Bool? {
        if line.contains("request_headers") {
            guard
                let peer = Self.firstCapture(Self.peerRegex, in: line),
                let method = Self.firstCapture(Self.methodRegex, in: line),
                let url = Self.firstCapture(Self.urlRegex, in: line),
                let headersB64 = Self.firstCapture(Self.headersB64Regex, in: line)
            else {
                return false
            }
            let decoded = decodeBase64Text(headersB64) ?? "<failed to decode headers>"
            let requestID = Self.firstCapture(Self.requestIDRegex, in: line)
            let key = transactionKey(requestID: requestID, peer: peer, method: method, url: url)
            return applyMetadata(PendingTransactionMeta(requestHeaders: decoded), toKey: key)
        }

        if line.contains("response_headers") {
            guard
                let peer = Self.firstCapture(Self.peerRegex, in: line),
                let method = Self.firstCapture(Self.methodRegex, in: line),
                let url = Self.firstCapture(Self.urlRegex, in: line),
                let headersB64 = Self.firstCapture(Self.headersB64Regex, in: line)
            else {
                return false
            }
            let decoded = decodeBase64Text(headersB64) ?? "<failed to decode headers>"
            let requestID = Self.firstCapture(Self.requestIDRegex, in: line)
            let key = transactionKey(requestID: requestID, peer: peer, method: method, url: url)
            return applyMetadata(PendingTransactionMeta(responseHeaders: decoded), toKey: key)
        }

        if line.contains("body inspection") {
            guard
                let peer = Self.firstCapture(Self.peerRegex, in: line),
                let method = Self.firstCapture(Self.methodRegex, in: line),
                let url = Self.firstCapture(Self.urlRegex, in: line),
                let direction = Self.firstCapture(Self.directionRegex, in: line),
                let sampleB64 = Self.firstCapture(Self.sampleB64Regex, in: line)
            else {
                return false
            }

            let preview = decodeBodyPreview(sampleB64)
            let requestID = Self.firstCapture(Self.requestIDRegex, in: line)
            let key = transactionKey(requestID: requestID, peer: peer, method: method, url: url)
            if direction == "request" {
                return applyMetadata(PendingTransactionMeta(requestBodyPreview: preview), toKey: key)
            }
            if direction == "response" {
                return applyMetadata(PendingTransactionMeta(responseBodyPreview: preview), toKey: key)
            }
            return false
        }

        return nil
    }

    private func transactionKey(requestID: String?, peer: String?, method: String, url: String) -> String {
        if let requestID, !requestID.isEmpty {
            return "id|\(requestID)"
        }
        return "\(peer ?? "-")|\(method)|\(url)"
    }

    private func applyMetadata(_ meta: PendingTransactionMeta, toKey key: String) -> Bool {
        guard !meta.isEmpty else { return false }

        if let entryID = latestLogIDByKey[key],
           let index = logIndexByID[entryID],
           logs.indices.contains(index)
        {
            var entry = logs[index]
            apply(meta: meta, to: &entry)
            logs[index] = entry
            return true
        }

        var pending = pendingMetaByKey[key] ?? PendingTransactionMeta()
        pending.merge(meta)
        pendingMetaByKey[key] = pending
        return false
    }

    private func apply(meta: PendingTransactionMeta, to entry: inout ProxyLogEntry) {
        if let value = meta.requestHeaders { entry.requestHeaders = value }
        if let value = meta.responseHeaders { entry.responseHeaders = value }
        if let value = meta.requestBodyPreview { entry.requestBodyPreview = value }
        if let value = meta.responseBodyPreview { entry.responseBodyPreview = value }
        if let value = meta.responseSizeBytes { entry.responseSizeBytes = value }
        if let value = meta.clientPlatform { entry.clientPlatform = value }
    }

    private func decodeBase64Text(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeHeaderPreview(_ value: String) -> String? {
        guard let decoded = decodeBase64Text(value) else { return nil }
        return normalizeHeaderPreview(decoded)
    }

    private func normalizeHeaderPreview(_ raw: String) -> String {
        let normalized = raw
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                guard let separator = trimmed.firstIndex(of: ":") else {
                    return trimmed
                }

                let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let valueStart = trimmed.index(after: separator)
                let value = trimmed[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    return "\(key):"
                }
                return "\(key): \(value)"
            }

        return normalized.joined(separator: "\n")
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

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmed(_ value: String) -> String {
        Self.trimmed(value)
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
    private static let requestIDRegex = try! NSRegularExpression(pattern: #"request_id=([^\s]+)"#)
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
}
