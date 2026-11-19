import Network
import NetworkExtension
import Security
import SystemConfiguration

@objc(CodexProvider)
final class CodexProvider: NETransparentProxyProvider {
    private let queue = DispatchQueue(label: "com.ashley.vpn.routing.flows")
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var selected: CodexProxyStatus.Selection?
    private var sessions = [UUID: RoutedConnection]()

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        guard let data = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["selection"] as? Data,
              update(data) else { completionHandler(POSIXError(.EINVAL)); return }
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let tcp = NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil,
                                localPrefix: 0, protocol: .TCP, direction: .outbound)
        let quic = ["0.0.0.0", "::"].map { address in
            NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: address, port: "443"), remotePrefix: 0,
                          localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound)
        }
        settings.includedNetworkRules = [tcp] + quic
        monitor.start(queue: queue)
        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    private func update(_ data: Data) -> Bool {
        let choice: CodexProxyStatus.Selection?
        if data.isEmpty { choice = nil }
        else {
            guard let decoded = try? JSONDecoder().decode(CodexProxyStatus.Selection.self, from: data),
                  decoded.id.hasPrefix("proxy:") || decoded.id.hasPrefix("vpn:") else { return false }
            choice = decoded
        }
        lock.lock()
        selected = choice
        lock.unlock()
        return true
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        completionHandler?(update(messageData) ? messageData : nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        monitor.cancel()
        queue.async {
            for session in Array(self.sessions.values) { session.finish(POSIXError(.ECANCELED)) }
            completionHandler()
        }
    }

    static func isDesktopRuntime(_ metadata: NEFlowMetaData) -> Bool {
        guard metadata.sourceAppSigningIdentifier == "codex", let token = metadata.sourceAppAuditToken else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return isVerifiedRuntime(code)
    }

    static func isVerifiedRuntime(_ code: SecCode) -> Bool {
        var requirement: SecRequirement?
        let rule = #"anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var executable: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, [], &info) == errSecSuccess,
              let url = (info as? [String: Any])?[kSecCodeInfoMainExecutable as String] as? URL else { return false }
        return url.path.hasSuffix(".app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard Self.isDesktopRuntime(flow.metaData) else { return false }
        lock.lock()
        let choice = selected
        lock.unlock()
        guard let choice else { return false }
        guard let tcp = flow as? NEAppProxyTCPFlow, let remote = tcp.remoteEndpoint as? NWHostEndpoint,
              let port = UInt16(remote.port), let destinationPort = Network.NWEndpoint.Port(rawValue: port) else {
            flow.closeReadWithError(POSIXError(.EPROTONOSUPPORT))
            flow.closeWriteWithError(POSIXError(.EPROTONOSUPPORT))
            return true
        }
        let local = ["127.0.0.1", "localhost", "::1"].contains(remote.hostname)
        if local {
            if choice.proxyURL?.port == Int(port), let url = choice.proxyURL,
               CodexProxyStatus.localProxyRoute(url)?.id == choice.id { return false }
            guard let existing = CodexProxyStatus.localProxyURLs().first(where: { $0.port == Int(port) }) else { return false }
            Task {
                do {
                    let request = try await LocalConnectRequest.read(tcp, socks: existing.scheme == "socks5h")
                    self.forward(tcp, to: request.endpoint, using: choice, request: request)
                } catch {
                    tcp.closeReadWithError(error)
                    tcp.closeWriteWithError(error)
                }
            }
            return true
        }
        let target = Network.NWEndpoint.hostPort(host: .init(tcp.remoteHostname ?? remote.hostname), port: destinationPort)
        forward(tcp, to: target, using: choice, request: nil)
        return true
    }

    private func forward(_ tcp: NEAppProxyTCPFlow, to target: Network.NWEndpoint, using choice: CodexProxyStatus.Selection,
                         request: LocalConnectRequest?) {
        queue.async {
            guard let upstream = self.upstream(to: target, using: choice) else {
                tcp.closeReadWithError(POSIXError(.ENETUNREACH))
                tcp.closeWriteWithError(POSIXError(.ENETUNREACH))
                return
            }
            let id = UUID()
            let session = RoutedConnection(flow: tcp, upstream: upstream,
                                           queue: self.queue, request: request) { self.sessions.removeValue(forKey: id) }
            self.sessions[id] = session
            session.start()
        }
    }

    func upstream(to target: Network.NWEndpoint, using choice: CodexProxyStatus.Selection) -> Upstream? {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        if choice.id.hasPrefix("vpn:") {
            guard let id = CodexProxyStatus.vpnService(choice.id),
                  let store = SCDynamicStoreCreate(nil, "Ashley VPN" as CFString, nil, nil) else { return nil }
            for family in ["IPv4", "IPv6"] {
                let key = "State:/Network/Service/\(id)/\(family)" as CFString
                let state = SCDynamicStoreCopyValue(store, key) as? [String: Any]
                if let name = state?["InterfaceName"] as? String,
                   let interface = monitor.currentPath.availableInterfaces.first(where: { $0.name == name }) {
                    parameters.requiredInterface = interface
                    return Upstream(connection: NWConnection(to: target, using: parameters), proxyScheme: nil, target: target)
                }
            }
            return nil
        }
        guard let url = choice.proxyURL, let host = url.host, let port = url.port,
              CodexProxyStatus.localProxyRoute(url)?.id == choice.id,
              let endpointPort = Network.NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let endpoint = Network.NWEndpoint.hostPort(host: .init(host), port: endpointPort)
        return Upstream(connection: NWConnection(to: endpoint, using: parameters), proxyScheme: url.scheme, target: target)
    }
}
