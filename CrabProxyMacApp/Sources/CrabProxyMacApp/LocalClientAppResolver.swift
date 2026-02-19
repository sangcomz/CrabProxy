import Foundation

actor LocalClientAppResolver {
    private let listenPort: UInt16
    private let snapshotTTL: TimeInterval = 0.9
    private var cachedPortToApp: [UInt16: String] = [:]
    private var lastSnapshotAt: Date = .distantPast

    init(listenPort: UInt16) {
        self.listenPort = listenPort
    }

    func resolveClientApp(peer: String, platformHint: ClientPlatform?) -> String? {
        guard let parsed = parsePeer(peer) else { return nil }

        if isLoopbackHost(parsed.host) {
            guard let sourcePort = parsed.port else { return nil }
            refreshSnapshotIfNeeded(force: false)
            if let app = cachedPortToApp[sourcePort] {
                return app
            }
            refreshSnapshotIfNeeded(force: true)
            return cachedPortToApp[sourcePort]
        }

        if platformHint == .mobile || isLikelyLANHost(parsed.host) {
            return "LAN \(parsed.host)"
        }

        return nil
    }

    private func refreshSnapshotIfNeeded(force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastSnapshotAt) < snapshotTTL {
            return
        }
        lastSnapshotAt = now
        cachedPortToApp = readSnapshot()
    }

    private func readSnapshot() -> [UInt16: String] {
        let lsofPath = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsofPath) else {
            return [:]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsofPath)
        process.arguments = [
            "-nP",
            "-w",
            "-iTCP",
            "-sTCP:ESTABLISHED",
            "-Fpcn",
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        // lsof returns 1 when no matching sockets exist.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return [:]
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return [:]
        }

        return parseLsofFieldOutput(text)
    }

    private func parseLsofFieldOutput(_ text: String) -> [UInt16: String] {
        var result: [UInt16: String] = [:]
        var currentPID: Int32?
        var currentCommand: String?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                currentPID = Int32(value)
            case "c":
                currentCommand = normalizeCommand(value)
            case "n":
                guard
                    let sourcePort = sourcePortIfConnectedToProxy(value),
                    let pid = currentPID
                else {
                    continue
                }
                let label = currentCommand ?? "PID \(pid)"
                result[sourcePort] = label
            default:
                continue
            }
        }

        return result
    }

    private func sourcePortIfConnectedToProxy(_ nameField: String) -> UInt16? {
        guard let arrowRange = nameField.range(of: "->") else { return nil }
        let source = String(nameField[..<arrowRange.lowerBound])
        let destination = String(nameField[arrowRange.upperBound...])
        guard endpointPort(destination) == listenPort else { return nil }
        return endpointPort(source)
    }

    private func endpointPort(_ endpoint: String) -> UInt16? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let head = String(trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        guard !head.isEmpty, let separator = head.lastIndex(of: ":") else {
            return nil
        }
        let portText = head[head.index(after: separator)...]
        return UInt16(portText.trimmingCharacters(in: CharacterSet(charactersIn: "[]()")))
    }

    private func parsePeer(_ peer: String) -> (host: String, port: UInt16?)? {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]")
        {
            let hostStart = trimmed.index(after: trimmed.startIndex)
            let host = String(trimmed[hostStart..<closing]).lowercased()
            var port: UInt16?
            let tail = trimmed[closing...]
            if let colon = tail.lastIndex(of: ":") {
                let portText = tail[tail.index(after: colon)...]
                port = UInt16(portText)
            }
            return (host: host, port: port)
        }

        if let separator = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<separator]).lowercased()
            let portText = trimmed[trimmed.index(after: separator)...]
            return (host: host, port: UInt16(portText))
        }

        return (host: trimmed.lowercased(), port: nil)
    }

    private func normalizeCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
}
