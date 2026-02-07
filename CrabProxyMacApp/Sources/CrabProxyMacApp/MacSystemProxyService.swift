import Foundation

struct MacSystemProxyStatus: Sendable {
    let networkService: String
    let interfaceName: String
    let webEnabled: Bool
    let webServer: String
    let webPort: Int
    let secureWebEnabled: Bool
    let secureWebServer: String
    let secureWebPort: Int

    var isEnabled: Bool {
        webEnabled || secureWebEnabled
    }

    var activeEndpoint: String {
        if secureWebEnabled, !secureWebServer.isEmpty {
            return "\(secureWebServer):\(secureWebPort)"
        }
        if webEnabled, !webServer.isEmpty {
            return "\(webServer):\(webPort)"
        }
        return "-"
    }
}

enum MacSystemProxyError: LocalizedError, Sendable {
    case commandFailed(command: String, message: String)
    case activeInterfaceNotFound
    case networkServiceNotFound(interface: String)
    case malformedOutput(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, message):
            if message.isEmpty {
                return "Command failed: \(command)"
            }
            return "Command failed (\(command)): \(message)"
        case .activeInterfaceNotFound:
            return "Could not find active network interface."
        case let .networkServiceNotFound(interface):
            return "Could not find network service for interface \(interface)."
        case let .malformedOutput(output):
            return "Unexpected networksetup output: \(output)"
        }
    }
}

enum MacSystemProxyService {
    private struct ProxyInfo {
        let enabled: Bool
        let server: String
        let port: Int
    }

    private struct ServiceOrderEntry {
        let serviceName: String
        let deviceName: String?
        let disabled: Bool
    }

    static func readStatus() throws -> MacSystemProxyStatus {
        let interfaceName = try activeInterfaceName()
        let serviceName = try networkServiceName(for: interfaceName)
        let web = try proxyInfo(for: serviceName, secure: false)
        let secure = try proxyInfo(for: serviceName, secure: true)

        return MacSystemProxyStatus(
            networkService: serviceName,
            interfaceName: interfaceName,
            webEnabled: web.enabled,
            webServer: web.server,
            webPort: web.port,
            secureWebEnabled: secure.enabled,
            secureWebServer: secure.server,
            secureWebPort: secure.port
        )
    }

    static func enable(host: String, port: Int) throws -> MacSystemProxyStatus {
        let status = try readStatus()

        try runNetworkSetup([
            "-setwebproxy", status.networkService, host, String(port),
        ])
        try runNetworkSetup([
            "-setsecurewebproxy", status.networkService, host, String(port),
        ])
        try runNetworkSetup(["-setwebproxystate", status.networkService, "on"])
        try runNetworkSetup(["-setsecurewebproxystate", status.networkService, "on"])

        return try readStatus()
    }

    static func disable() throws -> MacSystemProxyStatus {
        let status = try readStatus()

        try runNetworkSetup(["-setwebproxystate", status.networkService, "off"])
        try runNetworkSetup(["-setsecurewebproxystate", status.networkService, "off"])

        return try readStatus()
    }

    private static func activeInterfaceName() throws -> String {
        let output = try runCommand("/sbin/route", ["-n", "get", "default"])
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("interface:") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let interfaceName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !interfaceName.isEmpty {
                return interfaceName
            }
        }
        throw MacSystemProxyError.activeInterfaceNotFound
    }

    private static func networkServiceName(for interfaceName: String) throws -> String {
        let output = try runNetworkSetup(["-listnetworkserviceorder"])
        let entries = parseNetworkServiceOrder(output)
        let normalizedInterface = interfaceName.lowercased()

        if let exact = entries.first(where: {
            !$0.disabled && $0.deviceName?.lowercased() == normalizedInterface
        }) {
            return exact.serviceName
        }

        if let exactDisabled = entries.first(where: {
            $0.deviceName?.lowercased() == normalizedInterface
        }) {
            return exactDisabled.serviceName
        }

        if let hardwarePort = try hardwarePortName(for: interfaceName) {
            if let byPort = entries.first(where: {
                !$0.disabled && $0.serviceName.caseInsensitiveCompare(hardwarePort) == .orderedSame
            }) {
                return byPort.serviceName
            }
            if let byPartialPort = entries.first(where: {
                !$0.disabled && $0.serviceName.localizedCaseInsensitiveContains(hardwarePort)
            }) {
                return byPartialPort.serviceName
            }
        }

        if let firstEnabled = entries.first(where: { !$0.disabled }) {
            return firstEnabled.serviceName
        }

        let fallbackServices = try listAllNetworkServiceNames()
        if let firstFallback = fallbackServices.first {
            return firstFallback
        }

        throw MacSystemProxyError.networkServiceNotFound(interface: interfaceName)
    }

    private static func parseNetworkServiceOrder(_ output: String) -> [ServiceOrderEntry] {
        var entries: [ServiceOrderEntry] = []
        var currentServiceName: String?
        var currentDisabled = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("An asterisk") {
                continue
            }

            if line.hasPrefix("(*") && line.contains(")") {
                if let currentServiceName {
                    entries.append(
                        ServiceOrderEntry(
                            serviceName: currentServiceName,
                            deviceName: nil,
                            disabled: currentDisabled
                        )
                    )
                }

                let name = removeServicePrefixMarker(line)
                currentServiceName = name
                currentDisabled = true
                continue
            }

            if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
                let markerRange = line.index(after: line.startIndex)..<close
                let marker = line[markerRange]
                if marker.allSatisfy(\.isNumber) {
                    if let currentServiceName {
                        entries.append(
                            ServiceOrderEntry(
                                serviceName: currentServiceName,
                                deviceName: nil,
                                disabled: currentDisabled
                            )
                        )
                    }

                    let next = line.index(after: close)
                    if next < line.endIndex {
                        let candidate = line[next...].trimmingCharacters(in: .whitespaces)
                        currentServiceName = candidate.isEmpty ? nil : candidate
                        currentDisabled = false
                    } else {
                        currentServiceName = nil
                        currentDisabled = false
                    }
                    continue
                }
            }

            if let currentServiceName,
               line.hasPrefix("("),
               let device = parseDeviceFromOrderLine(line)
            {
                entries.append(
                    ServiceOrderEntry(
                        serviceName: currentServiceName,
                        deviceName: device,
                        disabled: currentDisabled
                    )
                )
                currentDisabled = false
                continue
            }
        }

        if let currentServiceName {
            entries.append(
                ServiceOrderEntry(
                    serviceName: currentServiceName,
                    deviceName: nil,
                    disabled: currentDisabled
                )
            )
        }

        return entries
    }

    private static func parseDeviceFromOrderLine(_ line: String) -> String? {
        guard let range = line.range(of: "Device:") else {
            return nil
        }
        let tail = line[range.upperBound...]
        var device = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let close = device.firstIndex(of: ")") {
            device = String(device[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let comma = device.firstIndex(of: ",") {
            device = String(device[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return device.isEmpty ? nil : device
    }

    private static func removeServicePrefixMarker(_ line: String) -> String {
        guard let close = line.firstIndex(of: ")") else {
            return line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let next = line.index(after: close)
        if next >= line.endIndex {
            return ""
        }
        return line[next...]
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hardwarePortName(for interfaceName: String) throws -> String? {
        let output = try runNetworkSetup(["-listallhardwareports"])
        var currentHardwarePort: String?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                currentHardwarePort = nil
                continue
            }

            if line.hasPrefix("Hardware Port:") {
                let value = line.dropFirst("Hardware Port:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentHardwarePort = value.isEmpty ? nil : value
                continue
            }

            if line.hasPrefix("Device:") {
                let value = line.dropFirst("Device:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value.caseInsensitiveCompare(interfaceName) == .orderedSame {
                    return currentHardwarePort
                }
            }
        }

        return nil
    }

    private static func listAllNetworkServiceNames() throws -> [String] {
        let output = try runNetworkSetup(["-listallnetworkservices"])
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("An asterisk")
            }
            .map { line in
                line.hasPrefix("*")
                    ? line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    : line
            }
            .filter { !$0.isEmpty }
    }

    private static func proxyInfo(for serviceName: String, secure: Bool) throws -> ProxyInfo {
        let args = secure
            ? ["-getsecurewebproxy", serviceName]
            : ["-getwebproxy", serviceName]
        let output = try runNetworkSetup(args)
        return try parseProxyInfo(output: output)
    }

    private static func parseProxyInfo(output: String) throws -> ProxyInfo {
        var enabled = false
        var server = ""
        var port = 0

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "enabled":
                enabled = parseBool(value)
            case "server":
                server = value
            case "port":
                port = Int(value) ?? 0
            default:
                break
            }
        }

        // If key fields are missing, treat as malformed to avoid applying wrong state.
        if output.contains("Enabled:") == false || output.contains("Port:") == false {
            throw MacSystemProxyError.malformedOutput(output)
        }

        return ProxyInfo(enabled: enabled, server: server, port: port)
    }

    private static func parseBool(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "yes" || normalized == "true" || normalized == "1" || normalized == "on"
    }

    @discardableResult
    private static func runNetworkSetup(_ args: [String]) throws -> String {
        try runCommand("/usr/sbin/networksetup", args)
    }

    private static func runCommand(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Force stable, non-localized command output for parsing.
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let command = ([executable] + args).joined(separator: " ")
            throw MacSystemProxyError.commandFailed(
                command: command,
                message: error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return output
    }
}
