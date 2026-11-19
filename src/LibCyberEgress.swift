import AppKit

@MainActor
final class LibCyberEgress {
    nonisolated static let routeID = "proxy:com.libcyber.pirate"

    private var probe: Task<Void, Never>?
    private var lease: URL?
    private var attemptedNode: String?
    private var lastCheck: TimeInterval = -.infinity

    func refresh(connected: Bool, selection: CodexProxyStatus.Selection?, force: Bool = false) {
        guard connected, selection?.id == Self.routeID else {
            probe?.cancel()
            probe = nil
            releaseRoute()
            attemptedNode = nil
            lastCheck = -.infinity
            return
        }
        guard probe == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCheck >= 20 else { return }
        lastCheck = now
        if force && lease.map({ FileManager.default.fileExists(atPath: $0.path) }) != true { attemptedNode = nil }

        probe = Task { [weak self] in
            let node = await Task.detached(priority: .utility) { Self.findFailingNode() }.value
            guard !Task.isCancelled, let self else { return }
            self.probe = nil
            // Keep the previous route until the current node requires a different host route.
            guard let node, self.attemptedNode != node else { return }
            self.releaseRoute()
            self.attemptedNode = node
            self.requestRoute(for: node)
        }
    }

    private func releaseRoute() {
        if let lease { try? FileManager.default.removeItem(at: lease) }
        lease = nil
    }

    private func requestRoute(for node: String) {
        guard let runner = Bundle.main.url(forResource: "libcyber-node-route", withExtension: "zsh") else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashley-egress-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let process = String(ProcessInfo.processInfo.processIdentifier)
            let session = try TerminalSession(runner: runner, arguments: [node, process, directory.path])
            lease = directory
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([session.profile], withApplicationAt: terminal, configuration: .init()) { _, error in
                if error != nil {
                    try? FileManager.default.removeItem(at: session.directory)
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated private static func findFailingNode() -> String? {
        guard let route = CodexProxyStatus.systemProxyForCodex(), route.id == routeID,
              case let .localProxy(url) = route.kind else { return nil }
        let started = Date()
        let probe = CodexProxyStatus.probeProxy(url)
        guard !probe.reachable, let port = probe.port else { return nil }
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LibCyber Desktop/coreOut.log")
        guard let file = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd(),
              (try? file.seek(toOffset: end - min(end, 512 * 1024))) != nil,
              let bytes = try? file.read(upToCount: 512 * 1024) else { return nil }
        return node(in: String(decoding: bytes, as: UTF8.self), port: port, since: started)
    }

    nonisolated static func node(in log: String, port: UInt16, since started: Date) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = ":\(port) --> chatgpt.com:443 error: failed to create session:"
        let sources = ["127.0.0.1" + request, "[::1]" + request]
        guard let addressPattern = try? NSRegularExpression(pattern: #"(?:->|dial tcp )([0-9]{1,3}(?:\.[0-9]{1,3}){3}):[0-9]+"#)
        else { return nil }
        let nodes = Set(log.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("time=\""), let error = sources.lazy.compactMap({ line.range(of: $0) }).first,
                  let stamp = line.dropFirst(6).split(separator: "\"").first,
                  let date = formatter.date(from: String(stamp)), date >= started else { return nil }
            let message = String(line[error.upperBound...])
            guard let match = addressPattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let address = Range(match.range(at: 1), in: message) else { return nil }
            return String(message[address])
        })
        return nodes.count == 1 ? nodes.first : nil
    }
}
