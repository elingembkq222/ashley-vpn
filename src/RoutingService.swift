import Foundation
import Darwin

@main
struct RoutingService {
    static let receiptPath = "/Library/Application Support/Ashley VPN Routing/installation.plist"
    static let daemonPath = "/Library/LaunchDaemons/com.ashley.vpn.routing-pac.plist"
    static let appIdentity = "/Applications/Ashley VPN.app/Contents/Resources/installation-id"

    static func validateInstallation(uid: uid_t) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        let receipt = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        let identity = try? String(contentsOfFile: appIdentity, encoding: .utf8)
        guard RoutingAuthorization.receiptMatches(receipt, identity: identity, uid: String(uid)) else {
            throw DomainRouting.Failure("安装级授权已失效")
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func stopOperation(_ action: String) throws {
        let job = "system/com.paloaltonetworks.gp.pangpsd"
        if action == "start-system" {
            guard try run("/bin/launchctl", ["enable", job]) == 0 else { throw DomainRouting.Failure("无法启用集团 VPN 服务") }
            if try run("/bin/launchctl", ["print", job]) != 0 {
                guard try run("/bin/launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"]) == 0 else {
                    throw DomainRouting.Failure("无法加载集团 VPN 服务")
                }
            }
            _ = try run("/bin/launchctl", ["kickstart", job])
            return
        }
        if ["disable", "bootout"].contains(action) {
            guard try run("/bin/launchctl", [action, job]) == 0 else { throw DomainRouting.Failure("无法停止集团 VPN 服务") }
            return
        }
        guard try run("/bin/launchctl", ["print", job]) != 0 else { throw DomainRouting.Failure("集团 VPN 服务仍在运行") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=", "-o", "ruid=", "-o", "comm="]
        process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in (String(data: bytes, encoding: .utf8) ?? "").split(separator: "\n") {
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, fields[1] == "0", let pid = Int32(fields[0]),
                  ["/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect", "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"].contains(String(fields[2])) else { continue }
            // Recheck the executable immediately before signalling, avoiding PID reuse.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == fields[2] else { continue }
            kill(pid, SIGKILL)
        }
    }

    static func ensurePAC(_ script: String) throws {
        for attempt in 0..<4 {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["--noproxy", "*", "--silent", "--fail", "--max-time", "2", DomainRouting.pacURL(for: script)]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, data == Data(script.utf8) { return }
            if attempt == 0 { _ = try run("/bin/launchctl", ["kickstart", "system/com.ashley.vpn.routing-pac"]) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw DomainRouting.Failure("本机 PAC 服务未就绪，已保留原网络设置")
    }

    static func handle(_ args: [String], uid: uid_t) -> RoutingIPC.Reply {
        do {
            try validateInstallation(uid: uid)
            if args == ["check"] { return .init(code: 0, message: "") }
            if args.count == 2, args[0] == "apply" {
                let script = try DomainRouting.scriptFromPayload(args[1])
                if let script { try ensurePAC(script) }
                try DomainRouting.applyPrivileged(script)
                return .init(code: 0, message: "")
            }
            if args.count == 1, ["disable", "bootout", "kill-residual", "start-system"].contains(args[0]) {
                try stopOperation(args[0]); return .init(code: 0, message: "")
            }
            if args == ["uninstall"] {
                try DomainRouting.applyPrivileged(nil)
                for path in [daemonPath, receiptPath, RoutingAuthorization.helper, RoutingIPC.path] {
                    if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                }
                try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: receiptPath).deletingLastPathComponent().path)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return .init(code: 0, message: "")
            }
            return .init(code: 64, message: "无效的网络组件请求")
        } catch { return .init(code: 77, message: error.localizedDescription) }
    }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["serve"], geteuid() == 0 {
                let data = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
                let receipt = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
                guard let value = receipt["uid"] as? String, let uid = uid_t(value), uid != 0 else { exit(77) }
                let server = PACServer()
                try server.start()
                try RoutingIPC.serve(uid: uid, handler: handle)
                withExtendedLifetime(server) { RunLoop.main.run() }
                return
            }
            let reply = try RoutingIPC.request(args)
            if !reply.message.isEmpty { FileHandle.standardError.write(Data((reply.message + "\n").utf8)) }
            exit(reply.code)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(77)
        }
    }
}
