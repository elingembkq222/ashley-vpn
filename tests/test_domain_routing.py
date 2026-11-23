from pathlib import Path
import subprocess
import unittest


class DomainRoutingTests(unittest.TestCase):
    def test_native_pac_and_preference_round_trip(self):
        source = Path(__file__).resolve().parents[1] / "src/DomainRouting.swift"
        checks = r"""
let original: [String: Any] = ["ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "https://previous.invalid/pac",
                               "ExceptionsList": ["intranet.example"], "HTTPEnable": 0]
let http = try DomainRouting.script(for: URL(string: "http://127.0.0.1:8890")!)
let socks = try DomainRouting.script(for: URL(string: "socks5h://127.0.0.1:8891")!)
let unavailable = try DomainRouting.script(for: nil)
let pending = CFNetworkCopyProxiesForAutoConfigurationScript(unavailable as CFString,
    URL(string: "https://chatgpt.com")! as CFURL, nil)!.takeRetainedValue() as! [[String: Any]]
precondition(pending.count == 1 && pending[0][kCFProxyHostNameKey as String] as? String == "selected-route-unavailable.invalid")
let first = try DomainRouting.configuration(original, script: http)
precondition(DomainRouting.configuredScript(first) == http)
var effectiveSettings = first
effectiveSettings.removeValue(forKey: "ProxyAutoConfigJavaScript")
precondition(DomainRouting.configuredScript(effectiveSettings) == http)
effectiveSettings["ProxyAutoConfigJavaScript"] = socks
precondition(DomainRouting.configuredScript(effectiveSettings) == nil)
let pacURL = URL(string: first["ProxyAutoConfigURLString"] as! String)!
precondition(pacURL.scheme == "data")
let decodedPAC = try String(contentsOf: pacURL, encoding: .utf8)
precondition(decodedPAC == http)
var legacy = first
legacy.removeValue(forKey: "ProxyAutoConfigURLString")
precondition(DomainRouting.configuredScript(legacy) == nil)
let migrated = try DomainRouting.configuration(legacy, script: http)
precondition((migrated as NSDictionary).isEqual(to: first))
let restoredLegacy = try DomainRouting.configuration(legacy, script: nil)
precondition((restoredLegacy as NSDictionary).isEqual(to: original))
let vpnOriginal: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigJavaScript": http,
                                  "HTTPEnable": 0, "ExceptionsList": [""]]
let vpnUpdated = try DomainRouting.dynamicConfiguration(vpnOriginal, script: socks)
precondition(DomainRouting.configuredScript(vpnUpdated) == socks)
let vpnReapplied = try DomainRouting.dynamicConfiguration(vpnUpdated, script: socks)
precondition((vpnUpdated as NSDictionary).isEqual(to: vpnReapplied))
let vpnRestored = try DomainRouting.dynamicConfiguration(vpnUpdated, script: nil)
precondition((vpnOriginal as NSDictionary).isEqual(to: vpnRestored))
do {
    _ = try DomainRouting.dynamicConfiguration(["ProxyAutoConfigEnable": 1,
        "ProxyAutoConfigJavaScript": http + "\n// modified externally"], script: socks)
    fatalError("adopted another application's PAC")
} catch is DomainRouting.Failure {}
let switched = try DomainRouting.configuration(first, script: socks)
precondition(DomainRouting.configuredScript(switched) == socks)
let restored = try DomainRouting.configuration(switched, script: nil)
precondition((original as NSDictionary).isEqual(to: restored))
let reapplied = try DomainRouting.configuration(switched, script: socks)
precondition((reapplied as NSDictionary).isEqual(to: switched))
var external = switched
external["ProxyAutoConfigURLString"] = "https://company.invalid/new"
precondition(DomainRouting.configuredScript(external) == nil)
let cleared = try DomainRouting.configuration(external, script: nil)
precondition(cleared["ProxyAutoConfigURLString"] as? String == "https://company.invalid/new")
do {
    _ = try DomainRouting.configuration(["ProxyAutoConfigEnable": 1], script: http)
    fatalError("replaced an existing PAC")
} catch is DomainRouting.Failure {}
for (script, port) in [(http, 8890), (socks, 8891)] {
    for (host, target) in [("chatgpt.com", true), ("CDN.OpenAI.com.", true), ("codex-portals.api.openai.com", true),
                           ("oaistatic.com", true), ("files.oaiusercontent.com", true), ("fakechatgpt.com", false),
                           ("openai.com.example.com", false), ("example.com", false)] {
        let url = URL(string: "https://" + host)!
        let proxies = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString, url as CFURL, nil)!
            .takeRetainedValue() as! [[String: Any]]
        precondition(proxies.count == 1)
        let route = proxies[0]
        if target {
            precondition(route[kCFProxyHostNameKey as String] as? String == "127.0.0.1")
            precondition(route[kCFProxyPortNumberKey as String] as? Int == port)
        } else { precondition(route[kCFProxyTypeKey as String] as? String == kCFProxyTypeNone as String) }
    }
}
"""
        subprocess.run(["xcrun", "swift", "-"], input=source.read_text() + checks, text=True, check=True, timeout=30)
