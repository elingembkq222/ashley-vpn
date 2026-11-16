import Foundation
import Security

private let args = CommandLine.arguments
guard args.count == 3, ["join", "save", "forget"].contains(args[1]),
      ["officewifi", "OfficeWiFi"].contains(args[2]) else {
    exit(2)
}
let directory = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().deletingLastPathComponent()
guard let rawID = try? String(contentsOf: directory.appendingPathComponent("installation-id"), encoding: .utf8),
      let installationID = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    exit(2)
}
let service = "com.ashley.vpn.wifi.\(installationID.uuidString)"

// The terminal supplies the password via stdin. Keep Keychain prompts out of
// the background watcher so a missing grant can be handled in the terminal.
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: args[2],
]
if args[1] == "forget" {
    let result = SecItemDelete(query as CFDictionary)
    exit(result == errSecSuccess || result == errSecItemNotFound ? 0 : 1)
}
if args[1] == "join" {
    var match: CFTypeRef?
    var request = query
    request[kSecReturnData as String] = true
    guard SecItemCopyMatching(request as CFDictionary, &match) == errSecSuccess,
          let password = match as? Data, !password.isEmpty else { exit(1) }
    // Use the credential locally. The helper never returns it to its caller.
    let input = Pipe()
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    command.arguments = ["-setairportnetwork", "en0", args[2], "-"]
    command.standardInput = input
    do {
        try command.run()
        try input.fileHandleForWriting.write(contentsOf: password + Data([0x0a]))
        try input.fileHandleForWriting.close()
    } catch {
        try? input.fileHandleForWriting.close()
        exit(1)
    }
    command.waitUntilExit()
    exit(command.terminationStatus)
}

let password = FileHandle.standardInput.readDataToEndOfFile()
guard !password.isEmpty else { exit(2) }
let value = [kSecValueData as String: password]
let result = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
if result == errSecDuplicateItem {
    exit(SecItemUpdate(query as CFDictionary, value as CFDictionary) == errSecSuccess ? 0 : 1)
}
exit(result == errSecSuccess ? 0 : 1)
