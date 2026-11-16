import Foundation

struct TerminalSession {
    let directory: URL
    let profile: URL

    init(runner: URL, action: String) throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appendingPathComponent("ashley-vpn-\(UUID().uuidString)", isDirectory: true)
        profile = directory.appendingPathComponent("Ashley VPN.terminal")
        let launcher = directory.appendingPathComponent("launch.zsh")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        do {
            let script = """
            /bin/rm -- \(Self.quote(launcher.path)) \(Self.quote(profile.path)) || exit 0
            /bin/rmdir -- \(Self.quote(directory.path))
            # Give the VPN operation its own foreground group for scoped cancellation.
            setopt monitor
            /bin/zsh -f \(Self.quote(runner.resolvingSymlinksInPath().path)) \(Self.quote(action))
            # Close the dedicated window after the operation exits, including on cancellation.
            exit 0
            """
            try Data(script.utf8).write(to: launcher, options: .atomic)
            let settings: [String: Any] = [
                "name": "Ashley VPN 操作",
                "type": "Window Settings",
                "ProfileCurrentVersion": 2.06,
                // The profile is scoped to the opened document. An imported
                // profile cannot replay the operation after its launcher runs.
                // Replace this window's login shell. Running as a child would
                // return to an idle prompt when the VPN operation ends.
                "CommandString": "exec /bin/zsh -f \(Self.quote(launcher.path))",
                "RunCommandAsShell": false,
                // Terminal closes this window on a clean exit.
                "shellExitAction": 1,
                "ShowWindowSettingsNameInTitle": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            try data.write(to: profile, options: .atomic)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
