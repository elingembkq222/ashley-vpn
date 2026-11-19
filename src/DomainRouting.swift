import CFNetwork
import Foundation
import Security
import SystemConfiguration

// Use the native PAC interpreter. The script contains only a validated loopback endpoint.
enum DomainRouting {
    private static let marker = "// Ashley VPN OpenAI domains v1\n"
    private static let backup = "AshleyVPNPreviousPAC"
    private static let pacKeys = ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"]

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func script(for endpoint: URL?) throws -> String {
        let proxy = try endpoint.map(proxyDirective) ?? "PROXY selected-route-unavailable.invalid:443"
        return marker + """
        function FindProxyForURL(url, host) {
          host = host.toLowerCase().replace(/\\.$/, "");
          var domains = ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"];
          for (var i = 0; i < domains.length; i++) {
            if (host === domains[i] || host.slice(-(domains[i].length + 1)) === "." + domains[i]) return "\(proxy)";
          }
          return "DIRECT";
        }
        """
    }

    private static func proxyDirective(_ url: URL) throws -> String {
        guard let host = url.host, ["127.0.0.1", "::1", "[::1]"].contains(host),
              let port = url.port, (1...65535).contains(port),
              ["http", "socks5h"].contains(url.scheme) else { throw Failure("所选线路没有可用的本机代理") }
        return (url.scheme == "http" ? "PROXY " : "SOCKS ") + (host == "127.0.0.1" ? host : "[::1]") + ":\(port)"
    }

    static func primaryServices() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "Ashley VPN" as CFString, nil, nil) else { return [] }
        return Set(["IPv4", "IPv6"].compactMap {
            let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\($0)" as CFString) as? [String: Any]
            return state?["PrimaryService"] as? String
        })
    }

    static func effectiveScript() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let url = URL(string: "https://chatgpt.com"),
              let rules = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return rules.first?[kCFProxyAutoConfigurationJavaScriptKey as String] as? String
    }

    static func configuration(_ current: [String: Any], script: String?) throws -> [String: Any] {
        var result = current
        let previous = result.removeValue(forKey: backup) as? [String: Any]
        let owned = previous != nil && (result["ProxyAutoConfigJavaScript"] as? String)?.hasPrefix(marker) == true
            && result["ProxyAutoConfigEnable"] as? Int == 1 && result["ProxyAutoConfigURLString"] == nil
        if owned, let previous {
            for key in pacKeys { result[key] = previous[key] }
        }
        guard let script else { return result }
        let otherProxies = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "FTPEnable", "RTSPEnable",
                            "GopherEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        guard !otherProxies.contains(where: { result[$0] as? Int == 1 }) else {
            throw Failure("当前网络已有代理设置，已保留原配置")
        }
        result[backup] = result.filter { pacKeys.contains($0.key) }
        result.removeValue(forKey: "ProxyAutoConfigURLString")
        result["ProxyAutoConfigEnable"] = 1
        result["ProxyAutoConfigJavaScript"] = script
        return result
    }

    static func apply(_ script: String?) throws {
        let primary = primaryServices()
        if script != nil && primary.isEmpty { throw Failure("等待活动网络") }
        func changes(in prefs: SCPreferences) throws -> [(SCNetworkProtocol, [String: Any])] {
            let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? []
            var found = Set<String>()
            var updates: [(SCNetworkProtocol, [String: Any])] = []
            for service in services {
                guard let id = SCNetworkServiceGetServiceID(service) as String?,
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
                else { continue }
                let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                let active = primary.contains(id)
                if active { found.insert(id) }
                guard active || current[backup] != nil else { continue }
                let next = try configuration(current, script: active ? script : nil)
                if !(current as NSDictionary).isEqual(to: next) { updates.append((proto, next)) }
            }
            if script != nil && found != primary { throw Failure("当前网络服务无法设置域名代理") }
            return updates
        }
        guard let read = SCPreferencesCreate(nil, "Ashley VPN" as CFString, nil) else { throw Failure("无法读取网络设置") }
        guard try !changes(in: read).isEmpty else { return }
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else {
            throw Failure("无法申请更改网络设置的权限")
        }
        defer { AuthorizationFree(auth, []) }
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "Ashley VPN" as CFString, nil, auth),
              SCPreferencesLock(prefs, true) else { throw Failure("未获得更改网络设置的权限") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        for (proto, next) in try changes(in: prefs) {
            guard SCNetworkProtocolSetConfiguration(proto, next as CFDictionary) else { throw Failure("无法更新域名代理规则") }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw Failure("macOS 未能应用域名代理规则")
        }
    }
}
