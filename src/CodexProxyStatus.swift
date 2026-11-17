import Foundation
import CFNetwork
import SystemConfiguration

enum CodexProxyStatus {
    struct Route: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case localProxy(url: URL)
            case systemVPN
        }

        let id: String
        let name: String
        let kind: Kind
    }

    struct Selection: Codable, Sendable {
        let id: String
        let name: String
        let proxyURL: URL?

        init(_ route: Route) {
            id = route.id
            name = route.name
            if case let .localProxy(url) = route.kind {
                proxyURL = url
            } else {
                proxyURL = nil
            }
        }
    }

    static func routes(savedProxy: URL?) -> [Route] {
        var proxies: [String: Route] = [:]
        let urls = localProxyURLs() + [savedProxy].compactMap { $0 }
        var checked = Set<URL>()
        for url in urls where checked.insert(url).inserted {
            if let proxy = localProxyRoute(url), proxies[proxy.id] == nil {
                proxies[proxy.id] = proxy
            }
        }

        let services = output("/usr/sbin/scutil", ["--nc", "list"]).map(vpnRoutes) ?? []
        return (Array(proxies.values) + services).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func systemProxyForCodex() -> Route? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let destination = URL(string: "https://chatgpt.com/backend-api/codex/responses"),
              let proxies = CFNetworkCopyProxiesForURL(destination as CFURL, settings)
                .takeRetainedValue() as? [[String: Any]],
              let proxy = proxies.first,
              let type = proxy[kCFProxyTypeKey as String] as? String,
              let host = proxy[kCFProxyHostNameKey as String] as? String,
              let port = proxy[kCFProxyPortNumberKey as String] as? Int else { return nil }
        let scheme: String
        if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String {
            scheme = "http"
        } else if type == kCFProxyTypeSOCKS as String {
            scheme = "socks5h"
        } else {
            return nil
        }
        let hosts = host.lowercased() == "localhost" ? ["127.0.0.1", "[::1]"] : [host]
        return hosts.lazy.compactMap { host in
            let address = host == "::1" ? "[::1]" : host
            return URL(string: "\(scheme)://\(address):\(port)").flatMap(localProxyRoute)
        }.first
    }

    private static func localProxyRoute(_ url: URL) -> Route? {
        guard let endpoint = loopbackEndpoint(url),
              let snapshot = output("/usr/sbin/lsof", ["-nP", "-iTCP@\(endpoint)", "-sTCP:LISTEN", "-Fp"])
        else { return nil }
        return proxyRoute(snapshot, url: url, pathForPID: executablePath)
    }

    static func vpnRoutes(_ snapshot: String) -> [Route] {
        return snapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty, parts[2].contains("["),
                  let id = parts[0].split(whereSeparator: \.isWhitespace).first(where: {
                      UUID(uuidString: String($0)) != nil
                  }),
                  !isGlobalProtect(parts.joined(separator: " ")) else { return nil }
            return Route(id: "vpn:" + id.lowercased(), name: String(parts[1]), kind: .systemVPN)
        }
    }

    static func proxyRoute(_ snapshot: String, url: URL, pathForPID: (Int32) -> String?) -> Route? {
        let listeners = Set(snapshot.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("p") })
        let owners = listeners.compactMap { Int32($0.dropFirst()).flatMap(pathForPID).flatMap(proxyOwner) }
        guard owners.count == listeners.count, Set(owners.map(\.id)).count == 1,
              let owner = owners.first else { return nil }
        return Route(id: owner.id, name: owner.name, kind: .localProxy(url: url))
    }

    private static func proxyOwner(_ path: String) -> (id: String, name: String)? {
        let executable = URL(fileURLWithPath: path)
        let components = executable.pathComponents
        let bundle = components.firstIndex { $0.lowercased().hasSuffix(".app") }
            .flatMap { NSURL.fileURL(withPathComponents: Array(components[...$0])) }
            .flatMap(Bundle.init(url:))
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundle?.bundleURL.deletingPathExtension().lastPathComponent
            ?? executable.lastPathComponent
        let identifier = bundle?.bundleIdentifier ?? executable.path
        guard !isGlobalProtect([name, identifier, path].joined(separator: " ")) else { return nil }
        return (id: "proxy:" + identifier, name: name)
    }

    private static func localProxyURLs() -> [URL] {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return [] }
        let kinds = [
            ("http", kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort),
            ("http", kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort),
            ("socks5h", kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort)
        ]
        return kinds.flatMap { (scheme, enabled, address, portKey) -> [URL] in
            guard settings[enabled as String] as? Int == 1,
                  let host = settings[address as String] as? String,
                  let port = settings[portKey as String] as? Int,
                  (1...65535).contains(port) else { return [] }
            let hosts = host.lowercased() == "localhost" ? ["127.0.0.1", "[::1]"] : [host]
            return hosts.compactMap { host in
                let address = host == "::1" ? "[::1]" : host
                guard let url = URL(string: "\(scheme)://\(address):\(port)"), loopbackEndpoint(url) != nil else {
                    return nil
                }
                return url
            }
        }
    }

    private static func loopbackEndpoint(_ url: URL) -> String? {
        guard url.scheme == "http" || url.scheme == "socks5h", let host = url.host, let port = url.port,
              (1...65535).contains(port), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil else { return nil }
        switch host {
        case "127.0.0.1": return "\(host):\(port)"
        case "::1", "[::1]": return "[::1]:\(port)"
        default: return nil
        }
    }

    static func proxyIsReachable(_ url: URL) -> Bool {
        guard loopbackEndpoint(url) != nil else { return false }
        let status = output("/usr/bin/curl", ["-q", "--silent", "--noproxy", "", "--proxy", url.absoluteString,
                                              "--connect-timeout", "4", "--max-time", "6", "--output", "/dev/null",
                                              "--write-out", "%{http_code}",
                                              "https://chatgpt.com/backend-api/codex/responses"])
        return status == "405" || status == "401"
    }

    static func vpnStatus(_ id: String) -> String? {
        guard let service = vpnService(id) else { return nil }
        return output("/usr/sbin/scutil", ["--nc", "status", service])?.split(whereSeparator: \.isNewline)
            .first.map(String.init)
    }

    static func changeVPN(_ id: String, connect: Bool) -> Bool {
        guard let service = vpnService(id) else { return false }
        return output("/usr/sbin/scutil", ["--nc", connect ? "start" : "stop", service]) != nil
    }

    static func vpnCarriesCodexTraffic(_ id: String) -> Bool {
        guard let service = vpnService(id), let store = SCDynamicStoreCreate(nil, "Ashley VPN" as CFString, nil, nil)
        else { return false }
        var routed = false
        for (family, key) in [("-inet", "IPv4"), ("-inet6", "IPv6")] {
            guard let route = output("/sbin/route", ["-n", "get", family, "chatgpt.com"]),
                  let interface = route.split(whereSeparator: \.isNewline).first(where: {
                      $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:")
                  })?.split(whereSeparator: \.isWhitespace).last else { continue }
            let stateKey = "State:/Network/Service/\(service)/\(key)" as CFString
            let state = SCDynamicStoreCopyValue(store, stateKey) as? [String: Any]
            guard String(interface) == state?["InterfaceName"] as? String else { return false }
            routed = true
        }
        return routed
    }

    private static func vpnService(_ id: String) -> String? {
        guard id.hasPrefix("vpn:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) else { return nil }
        return uuid.uuidString
    }

    private static func isGlobalProtect(_ identity: String) -> Bool {
        let value = identity.lowercased().filter { !$0.isWhitespace }
        return value.contains("globalprotect") || value.contains("paloaltonetworks") || value.contains("集团vpn")
    }

    private static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func executablePath(of pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
    }
}
