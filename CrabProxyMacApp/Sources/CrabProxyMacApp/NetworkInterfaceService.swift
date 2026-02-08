import Foundation
import Darwin

enum NetworkInterfaceService {
    static func preferredLANIPv4Address() -> String? {
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

    private static func shouldIgnoreForProxy(_ interfaceName: String) -> Bool {
        let value = interfaceName.lowercased()
        let ignoredPrefixes = [
            "lo", "utun", "awdl", "llw", "bridge", "vmnet", "vboxnet", "docker", "tap", "tun",
        ]
        return ignoredPrefixes.contains { value.hasPrefix($0) }
    }

    private static func interfacePriority(_ interfaceName: String) -> Int {
        let value = interfaceName.lowercased()
        if value == "en0" { return 0 }
        if value == "en1" { return 1 }
        if value == "en2" { return 2 }
        if value.hasPrefix("en") { return 10 }
        return 50
    }
}
