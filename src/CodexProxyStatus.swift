import Foundation
import SystemConfiguration

enum CodexProxyStatus {
    static let codexIdentifier = "com.openai.codex"

    struct Route: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case localProxy(connected: Bool)
            case systemVPN
        }

        let id: String
        let name: String
        let kind: Kind
    }

    static func routes(codex: URL) -> [Route] {
        let codexPath = codex.resolvingSymlinksInPath().path + "/Contents/"
        var proxies: [String: Route] = [:]
        for endpoint in localProxyEndpoints() {
            guard let snapshot = output("/usr/sbin/lsof", ["-nP", "-iTCP@\(endpoint)", "-FfpnT", "-Ts"]) else {
                continue
            }
            for proxy in proxyRoutes(snapshot, endpoint: endpoint, codexPath: codexPath, pathForPID: executablePath) {
                if let prior = proxies[proxy.id], case .localProxy(true) = prior.kind { continue }
                proxies[proxy.id] = proxy
            }
        }

        let services = output("/usr/sbin/scutil", ["--nc", "list"]).map(vpnRoutes) ?? []
        return (Array(proxies.values) + services).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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

    static func proxyRoutes(_ snapshot: String, endpoint: String, codexPath: String,
                            pathForPID: (Int32) -> String?) -> [Route] {
        var executable: String?
        var socket = ""
        var listeners = Set<String>()
        var connected = false
        for line in snapshot.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                executable = Int32(line.dropFirst()).flatMap(pathForPID)
                socket = ""
            } else if line.hasPrefix("f") {
                socket = ""
            } else if line.hasPrefix("n") {
                socket = String(line.dropFirst())
            } else if line == "TST=LISTEN", let executable {
                listeners.insert(executable)
            } else if line == "TST=ESTABLISHED", executable?.hasPrefix(codexPath) == true,
                      socket.hasSuffix("->" + endpoint) {
                connected = true
            }
        }
        let routes = listeners.compactMap(proxyOwner)
        let ids = Set(routes.map(\.id))
        guard routes.count == listeners.count, ids.count == 1, let proxy = routes.first else { return [] }
        return [Route(id: proxy.id, name: proxy.name, kind: .localProxy(connected: connected))]
    }

    private static func proxyOwner(_ path: String) -> Route? {
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
        return Route(id: "proxy:" + identifier, name: name, kind: .localProxy(connected: false))
    }

    private static func localProxyEndpoints() -> [String] {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return [] }
        let kinds = [
            (kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort),
            (kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort),
            (kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort)
        ]
        let endpoints = kinds.flatMap { (enabled, address, portKey) -> [String] in
            guard settings[enabled as String] as? Int == 1,
                  let host = settings[address as String] as? String,
                  let port = settings[portKey as String] as? Int,
                  (1...65535).contains(port) else { return [] }
            switch host.lowercased() {
            case "localhost": return ["127.0.0.1:\(port)", "[::1]:\(port)"]
            case "127.0.0.1": return ["127.0.0.1:\(port)"]
            case "::1", "[::1]": return ["[::1]:\(port)"]
            default: return []
            }
        }
        return Set(endpoints).sorted()
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
