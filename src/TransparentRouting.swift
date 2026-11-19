import NetworkExtension
import SystemExtensions

@MainActor
final class TransparentRouting: NSObject, OSSystemExtensionRequestDelegate {
    static let providerID = "com.ashley.vpn.companion.routing"
    private var activation: CheckedContinuation<Void, Error>?
    private var activated = false
    private var manager: NETransparentProxyManager?
    private var message = "Codex 使用默认线路"
    private var configured = false

    var needsReconnect: Bool {
        configured && manager?.connection.status == .disconnected
    }

    var policyActive: Bool { configured && manager?.connection.status == .connected }

    var status: String {
        if configured && manager?.connection.status != .connected { return "Codex 分流扩展未连接" }
        return message
    }

    func apply(_ selection: CodexProxyStatus.Selection?) async {
        configured = false
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(Self.providerID).systemextension")
        guard FileManager.default.fileExists(atPath: embedded.path) else {
            message = selection == nil ? "Codex 使用默认线路" : "未应用 · 需要包含已签名网络扩展的 Ashley VPN"
            return
        }
        do {
            if #unavailable(macOS 14), selection != nil { throw RoutingError("Codex 分流需要 macOS 14 或更新版本") }
            message = "正在应用 Codex 线路"
            if selection != nil && !activated {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    activation = continuation
                    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.providerID, queue: .main)
                    request.delegate = self
                    OSSystemExtensionManager.shared.submitRequest(request)
                }
                activated = true
            }
            let configs = try await NETransparentProxyManager.loadAllFromPreferences()
            let existing = configs.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID }
            if selection == nil && existing == nil {
                manager = nil
                message = "Codex 使用默认线路"
                return
            }
            let config = existing ?? NETransparentProxyManager()
            manager = config
            let data = try selection.map { try JSONEncoder().encode($0) } ?? Data()
            let settings = NETunnelProviderProtocol()
            settings.providerBundleIdentifier = Self.providerID
            settings.serverAddress = "Ashley VPN Codex"
            settings.providerConfiguration = ["selection": data]
            config.protocolConfiguration = settings
            config.localizedDescription = "Ashley VPN · Codex 分流"
            config.isEnabled = true
            try await config.saveToPreferences()
            try await config.loadFromPreferences()
            guard let session = config.connection as? NETunnelProviderSession else { throw RoutingError("无法打开网络扩展会话") }
            if selection == nil && [.disconnected, .invalid].contains(session.status) {
                message = "Codex 使用默认线路"
                return
            }
            if [.disconnected, .invalid].contains(session.status) { try session.startTunnel() }
            for _ in 0..<80 where session.status != .connected {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            guard session.status == .connected else { throw RoutingError("网络扩展未连接") }
            try await notify(session, data: data)
            configured = selection != nil
            if let selection {
                message = selection.id.hasPrefix("proxy:") && selection.proxyURL == nil
                    ? "等待 \(selection.name) 的代理端口"
                    : "已应用到 Codex 新连接 · \(selection.name)"
            } else { message = "Codex 使用默认线路" }
        } catch { message = "未确认应用 · \(error.localizedDescription)" }
    }

    func uninstall() async throws {
        let configs = try await NETransparentProxyManager.loadAllFromPreferences()
        for config in configs where (config.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID {
            config.connection.stopVPNTunnel()
            try await config.removeFromPreferences()
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                activation = continuation
                let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.providerID, queue: .main)
                request.delegate = self
                OSSystemExtensionManager.shared.submitRequest(request)
            }
        } catch let error as NSError where error.domain == OSSystemExtensionErrorDomain &&
            error.code == OSSystemExtensionError.Code.extensionNotFound.rawValue { return }
    }

    private func notify(_ session: NETunnelProviderSession, data: Data) async throws {
        let reply: Data? = try await withCheckedThrowingContinuation { continuation in
            do { try session.sendProviderMessage(data) { continuation.resume(returning: $0) } }
            catch { continuation.resume(throwing: error) }
        }
        guard reply == data else { throw RoutingError("网络扩展未确认线路") }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.message = "等待在系统设置中允许 Ashley VPN 网络扩展" }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.activation?.resume(throwing: error); self.activation = nil }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if result == .completed { self.activation?.resume() }
            else { self.activation?.resume(throwing: RoutingError("macOS 需要重新启动才能启用扩展")) }
            self.activation = nil
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}

private struct RoutingError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
