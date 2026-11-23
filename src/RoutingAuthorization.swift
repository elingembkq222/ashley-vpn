import Foundation

enum RoutingAuthorization {
    static let helper = "/Library/PrivilegedHelperTools/com.ashley.vpn.routing"
    private static var lastMessage = ""
    private static let attemptKey: String = {
        let contents = Bundle.main.url(forResource: "installation-id", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let identity = contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return "routingAuthorizationAttempted." + identity
    }()

    static func receiptMatches(_ receipt: [String: Any], identity: String?, uid: String?) -> Bool {
        guard let expected = receipt["installation"] as? String,
              let owner = receipt["uid"] as? String else { return false }
        return identity?.trimmingCharacters(in: .whitespacesAndNewlines) == expected && uid == owner
    }

    private static func run(_ arguments: [String]) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: helper) else { return 77 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lastMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return process.terminationStatus
    }

    static func apply(_ script: String?) throws {
        if try run(["check"]) != 0 {
            guard script != nil else { return }
            guard !UserDefaults.standard.bool(forKey: attemptKey) else {
                throw DomainRouting.Failure("安装级授权未完成，自动切换已停止重复请求")
            }
            UserDefaults.standard.set(true, forKey: attemptKey)
            guard let installer = Bundle.main.url(forResource: "setup-routing-authorization", withExtension: "sh") else {
                throw DomainRouting.Failure("缺少网络代理授权组件，请重新安装助手")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
            on run argv
              do shell script ("/bin/sh " & quoted form of item 1 of argv & " " & quoted form of item 2 of argv) with administrator privileges
            end run
            """, installer.path, String(getuid())]
            process.standardOutput = FileHandle.nullDevice
            let diagnostics = Pipe()
            process.standardError = diagnostics
            try process.run()
            let errorData = diagnostics.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var ready = false
            if process.terminationStatus == 0 {
                for _ in 0..<50 {
                    if try run(["check"]) == 0 { ready = true; break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            guard ready else {
                let detail = String(data: errorData, encoding: .utf8) ?? ""
                throw DomainRouting.Failure("安装级授权未完成，自动切换不会重复请求密码。" + detail)
            }
        }
        let payload = script.map { Data($0.utf8).base64EncodedString() } ?? "-"
        guard try run(["apply", payload]) == 0 else {
            throw DomainRouting.Failure(lastMessage.isEmpty ? "网络代理组件未能应用线路" : lastMessage)
        }
    }
}
