import Foundation
import Network

/// Finds the TV on the local network by probing every address in the Mac's /24 subnet
/// for an FTP server (a "220" greeting) on the given port. The TV's IP can change when
/// the router reassigns it, so this saves digging through TV settings.
enum NetworkScanner {
    struct Interface { let address: String; let prefix: String }

    static func localIPv4() -> Interface? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if ip.hasPrefix("169.254.") { continue }
            candidates.append((name, ip))
        }
        // Prefer Wi-Fi/Ethernet (en*) over VPN tunnels.
        let pick = candidates.first(where: { $0.name.hasPrefix("en") }) ?? candidates.first
        guard let ip = pick?.ip else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return Interface(address: ip, prefix: parts[0...2].joined(separator: "."))
    }

    /// With `expectFTPGreeting`, only servers that greet like FTP ("220") count; otherwise any open port does (adb).
    static func scan(port: Int, expectFTPGreeting: Bool = true) async -> [String] {
        guard let iface = localIPv4(), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return [] }
        return await withTaskGroup(of: String?.self) { group in
            for i in 1...254 {
                let ip = "\(iface.prefix).\(i)"
                if ip == iface.address { continue }
                group.addTask { await probe(host: ip, port: nwPort, expectFTPGreeting: expectFTPGreeting) ? ip : nil }
            }
            var found: [String] = []
            for await r in group { if let r { found.append(r) } }
            return found.sorted { $0.split(separator: ".").last.flatMap { Int($0) } ?? 0 < $1.split(separator: ".").last.flatMap { Int($0) } ?? 0 }
        }
    }

    private static func probe(host: String, port: NWEndpoint.Port, expectFTPGreeting: Bool) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let once = Once()
            let finish: (Bool) -> Void = { ok in
                if once.claim() { conn.cancel(); cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard expectFTPGreeting else { finish(true); return }
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
                        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        finish(text.hasPrefix("220"))
                    }
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }
}

final class Once {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
