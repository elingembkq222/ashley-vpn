import AppKit

@MainActor
struct TerminalSession {
    let directory: URL
    let profile: URL

    init(runner: URL, arguments: [String]) throws {
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
            export ASHLEY_VPN_TERMINAL_PROFILE=1
            exec /bin/zsh -f \(Self.quote(runner.resolvingSymlinksInPath().path)) \(arguments.map(Self.quote).joined(separator: " "))
            """
            try Data(script.utf8).write(to: launcher, options: .atomic)
            var settings: [String: Any] = [
                "name": "Ashley VPN",
                "type": "Window Settings",
                "ProfileCurrentVersion": 2.07,
                "columnCount": 80,
                "rowCount": 24,
                // The banner uses single-cell box drawing and block glyphs.
                "EastAsianAmbiguousWide": false,
                "CursorType": 2,
                "CursorBlink": true,
                "UseBoldFonts": true,
                "UseBrightBold": false,
                // The profile is scoped to the opened document. An imported
                // profile cannot replay the operation after its launcher runs.
                // The interactive shell gives the operation the foreground
                // terminal for password input and a group for cancellation.
                // Exit this dedicated shell after the operation returns.
                "CommandString": "/bin/zsh -f \(Self.quote(launcher.path)); exit 0",
                "RunCommandAsShell": false,
                // Terminal closes this window on a clean exit.
                "shellExitAction": 1,
                "ShowWindowSettingsNameInTitle": true,
                "ShowShellCommandInTitle": false,
                "ShowActiveProcessInTitle": false,
                "ShowActiveProcessArgumentsInTitle": false,
                "ShowTTYNameInTitle": false,
                "ShowDimensionsInTitle": false
            ]
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            settings.merge(try Self.appearanceSettings(dark: dark)) { _, themed in themed }
            settings.merge(Self.defaultLayout()) { _, inherited in inherited }
            let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            try data.write(to: profile, options: .atomic)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func defaultLayout(preferences: UserDefaults? = UserDefaults(suiteName: "com.apple.Terminal")) -> [String: Any] {
        let name = preferences?.string(forKey: "Default Window Settings") ?? "Basic"
        let profiles = preferences?.dictionary(forKey: "Window Settings")
        let saved = profiles?[name] as? [String: Any] ?? [:]
        let standard = builtInProfile("Basic")
        let selected = name == "Basic" ? standard : builtInProfile(name)
        var layout: [String: Any] = [:]
        for key in ["columnCount", "rowCount", "Font", "FontWidthSpacing", "FontHeightSpacing", "FontAntialias"] {
            layout[key] = saved[key] ?? selected[key] ?? standard[key]
        }
        return layout
    }

    private static func builtInProfile(_ name: String) -> [String: Any] {
        guard !name.isEmpty, !(name as NSString).isAbsolutePath, !name.contains("/") else { return [:] }
        let directory = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings")
        let source = directory.appendingPathComponent(name).appendingPathExtension("terminal")
        guard let data = try? Data(contentsOf: source),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return values
    }

    private static func appearanceSettings(dark: Bool) throws -> [String: Data] {
        // Light and dark palette values from gpxl/cc-terminal-theme.
        let colors: [String: UInt32] = [
            "BackgroundColor": dark ? 0x1a1a1a : 0xffffff,
            "TextColor": dark ? 0xffffff : 0x000000,
            "BoldTextColor": dark ? 0xffffff : 0x000000,
            "CursorColor": 0xd77757,
            "SelectionColor": dark ? 0x264f78 : 0xb4d5ff,
            "ANSIRedColor": dark ? 0xff6b80 : 0xab2b3f,
            "ANSIBrightRedColor": 0xd77757,
            "ANSIGreenColor": dark ? 0x4eba65 : 0x2c7a39,
            "ANSIYellowColor": dark ? 0xffc107 : 0x966c1e
        ]
        var archived = try colors.mapValues { hex in
            let color = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                green: CGFloat((hex >> 8) & 255) / 255,
                                blue: CGFloat(hex & 255) / 255, alpha: 1)
            return try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        }
        let font = NSFont(name: "SFMono-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        archived["Font"] = try NSKeyedArchiver.archivedData(withRootObject: font, requiringSecureCoding: true)
        return archived
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
