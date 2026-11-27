import CFNetwork
import Foundation
import Security
import SystemConfiguration

// Keep the native script and a PAC URL in sync: Chromium reads only the URL on macOS.
enum DomainRouting {
    private static let marker = "// Ashley VPN OpenAI domains v1\n"
    private static let backup = "AshleyVPNPreviousPAC"
    private static let pacKeys = ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"]
    private static let dataURLPrefix = "data:application/x-ns-proxy-autoconfig;base64,"

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
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return configuredScript(settings)
    }

    static let pacPort: UInt16 = 18946

    static func pacURL(for script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "http://127.0.0.1:\(pacPort)/proxy/" + encoded + ".pac"
    }

    static func scriptFromPACURL(_ value: String) -> String? {
        let prefix = "http://127.0.0.1:\(pacPort)/proxy/"
        guard value.hasPrefix(prefix), value.hasSuffix(".pac"), value.count < 4096 else { return nil }
        var encoded = String(value.dropFirst(prefix.count).dropLast(4))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), let script = String(data: bytes, encoding: .utf8),
              isGeneratedScript(script), pacURL(for: script) == value else { return nil }
        return script
    }

    static func configuredScript(_ settings: [String: Any]) -> String? {
        guard settings["ProxyAutoConfigEnable"] as? Int == 1,
              let url = settings["ProxyAutoConfigURLString"] as? String,
              let script = scriptFromPACURL(url) else { return nil }
        if let inline = settings["ProxyAutoConfigJavaScript"] as? String, inline != script { return nil }
        return script
    }

    static func configuration(_ current: [String: Any], script: String?) throws -> [String: Any] {
        var result = current
        let previous = result.removeValue(forKey: backup) as? [String: Any]
        let inline = result["ProxyAutoConfigJavaScript"] as? String
        // Also recognize the old inline-only configuration so an upgrade restores its original backup.
        let owned = previous != nil && inline?.hasPrefix(marker) == true
            && result["ProxyAutoConfigEnable"] as? Int == 1
            && (result["ProxyAutoConfigURLString"] == nil || configuredScript(result) != nil
                || inline.map { result["ProxyAutoConfigURLString"] as? String == dataURLPrefix + Data($0.utf8).base64EncodedString() } == true)
        if owned, let previous {
            for key in pacKeys { result[key] = previous[key] }
        }
        guard let script else { return result }
        let otherProxies = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "FTPEnable", "RTSPEnable",
                            "GopherEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        let restoringLegacy = owned && result["ProxyAutoConfigURLString"] == nil
            && (result["ProxyAutoConfigJavaScript"] as? String).map(isGeneratedScript) == true
        guard !otherProxies.contains(where: {
            result[$0] as? Int == 1 && !($0 == "ProxyAutoConfigEnable" && restoringLegacy)
        }) else {
            throw Failure("当前网络已有代理设置，已保留原配置")
        }
        result[backup] = result.filter { pacKeys.contains($0.key) }
        result["ProxyAutoConfigURLString"] = pacURL(for: script)
        result["ProxyAutoConfigEnable"] = 1
        result["ProxyAutoConfigJavaScript"] = script
        return result
    }

    static func apply(_ script: String?, retryAuthorization: Bool = false) throws {
        try RoutingAuthorization.apply(script, retryAuthorization: retryAuthorization)
    }

    static func applyPrivileged(_ script: String?) throws {
        guard geteuid() == 0 else { throw Failure("网络代理组件需要安装级授权") }
        let primary = primaryServices()
        if script != nil && primary.isEmpty { throw Failure("等待活动网络") }
        func changes(in prefs: SCPreferences) throws -> [(SCNetworkProtocol, [String: Any])] {
            let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? []
            var updates: [(SCNetworkProtocol, [String: Any])] = []
            for service in services {
                guard let id = SCNetworkServiceGetServiceID(service) as String?,
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
                else { continue }
                let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                let active = primary.contains(id)
                guard active || current[backup] != nil else { continue }
                let next = try configuration(current, script: active ? script : nil)
                if !(current as NSDictionary).isEqual(to: next) { updates.append((proto, next)) }
            }
            return updates
        }
        guard let read = SCPreferencesCreate(nil, "Ashley VPN" as CFString, nil) else { throw Failure("无法读取网络设置") }
        let persisted = Set((SCNetworkServiceCopyAll(read) as? [SCNetworkService] ?? []).compactMap {
            SCNetworkServiceGetServiceID($0) as String?
        })
        // GlobalProtect publishes gpd.pan in the dynamic store, without an SCNetworkService.
        try applyDynamic(script, primary: primary.subtracting(persisted))
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

    private static func dynamicChanges(_ store: SCDynamicStore, script: String?, primary: Set<String>) throws -> [(String, [String: Any])] {
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/Proxies" as CFString) as? [String] ?? []
        let active = Set(primary.map { "State:/Network/Service/\($0)/Proxies" })
        return try Set(keys).union(active).compactMap { key in
            let current = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
            guard active.contains(key) || current[backup] != nil else { return nil }
            let next = try dynamicConfiguration(current, script: active.contains(key) ? script : nil)
            return (current as NSDictionary).isEqual(to: next) ? nil : (key, next)
        }
    }

    static func dynamicConfiguration(_ current: [String: Any], script: String?) throws -> [String: Any] {
        var adopted = current
        // Earlier local repairs wrote an inline-only rule directly to the VPN service.
        if adopted[backup] == nil, adopted["ProxyAutoConfigURLString"] == nil,
           let legacy = adopted["ProxyAutoConfigJavaScript"] as? String, isGeneratedScript(legacy) {
            adopted[backup] = adopted.filter { pacKeys.contains($0.key) }
        }
        return try configuration(adopted, script: script)
    }

    private static func isGeneratedScript(_ value: String) -> Bool {
        if value == (try? script(for: nil)) { return true }
        guard let directive = value.components(separatedBy: "return \"").dropFirst().first?.components(separatedBy: "\"").first else { return false }
        for (prefix, scheme) in [("PROXY ", "http"), ("SOCKS ", "socks5h")] where directive.hasPrefix(prefix) {
            if let endpoint = URL(string: scheme + "://" + directive.dropFirst(prefix.count)),
               value == (try? script(for: endpoint)) { return true }
        }
        return false
    }

    private static func applyDynamic(_ script: String?, primary: Set<String>) throws {
        guard let store = SCDynamicStoreCreate(nil, "Ashley VPN" as CFString, nil, nil) else { throw Failure("无法读取 VPN 代理设置") }
        guard try !dynamicChanges(store, script: script, primary: primary).isEmpty else { return }
        guard geteuid() == 0 else { throw Failure("网络代理组件需要安装级授权") }
        for (key, next) in try dynamicChanges(store, script: script, primary: primary) {
            guard SCDynamicStoreSetValue(store, key as CFString, next as CFDictionary) else { throw Failure("无法更新 VPN 域名代理") }
        }
    }

    static func scriptFromPayload(_ payload: String) throws -> String? {
        if payload == "-" { return nil }
        guard payload.count < 4096, let bytes = Data(base64Encoded: payload),
              let script = String(data: bytes, encoding: .utf8), isGeneratedScript(script)
        else { throw Failure("无效的域名代理规则") }
        return script
    }
}
