import Foundation
import SystemConfiguration

enum CodexProxyStatus: String, Sendable {
    case unavailable = "LibCyber 正在运行，本地代理未就绪"
    case waiting = "LibCyber 代理已就绪，等待 Codex 建立连接"
    case observed = "已检测到 Codex 连接 LibCyber"

    static let codexIdentifier = "com.openai.codex"
    static let libCyberIdentifier = "com.libcyber.pirate"

    static func check(codex: URL, libCyber: URL) -> Self {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any],
              settings[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1,
              let host = settings[kSCPropNetProxiesHTTPSProxy as String] as? String,
              let port = settings[kSCPropNetProxiesHTTPSPort as String] as? Int,
              (1...65535).contains(port) else { return .unavailable }
        let addresses: [String]
        switch host.lowercased() {
        case "localhost": addresses = ["127.0.0.1", "[::1]"]
        case "127.0.0.1": addresses = ["127.0.0.1"]
        case "::1", "[::1]": addresses = ["[::1]"]
        default: return .unavailable
        }
        let codexPath = codex.resolvingSymlinksInPath().path + "/Contents/"
        let libCyberPath = libCyber.resolvingSymlinksInPath().path + "/Contents/"
        var result = Self.unavailable
        for address in addresses {
            let endpoint = "\(address):\(port)"
            guard let snapshot = sockets(at: endpoint) else { continue }
            let status = classify(snapshot, endpoint: endpoint) { pid in
                guard let path = executablePath(of: pid) else { return nil }
                if path.hasPrefix(codexPath) { return codexIdentifier }
                if path.hasPrefix(libCyberPath) { return libCyberIdentifier }
                return nil
            }
            if status == .observed { return status }
            if status == .waiting { result = status }
        }
        return result
    }

    static func classify(_ snapshot: String, endpoint: String, owner: (Int32) -> String?) -> Self {
        var identifier: String?
        var connection = ""
        var proxyListening = false
        var codexUsingProxy = false
        for line in snapshot.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                identifier = Int32(line.dropFirst()).flatMap(owner)
            } else if line.hasPrefix("f") {
                connection = ""
            } else if line.hasPrefix("n") {
                connection = String(line.dropFirst())
            } else if line == "TST=LISTEN",
                      identifier == libCyberIdentifier {
                proxyListening = true
            } else if line == "TST=ESTABLISHED",
                      identifier == codexIdentifier, connection.hasSuffix("->" + endpoint) {
                codexUsingProxy = true
            }
        }
        guard proxyListening else { return .unavailable }
        return codexUsingProxy ? .observed : .waiting
    }

    private static func sockets(at endpoint: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP@\(endpoint)", "-FfpnT", "-Ts"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let snapshot = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: snapshot, as: UTF8.self)
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
