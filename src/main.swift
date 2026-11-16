import AppKit

@MainActor
final class AshleyVPN: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.image = menuIcon()
            button.imagePosition = .imageLeading
            button.title = "Ashley VPN"
        }

        let menu = NSMenu()
        addItem("开启 VPN", action: #selector(connect), to: menu)
        addItem("关闭 VPN", action: #selector(disconnect), to: menu)
        menu.addItem(.separator())
        addItem("退出 Ashley VPN 图标", action: #selector(quit), to: menu)
        item.menu = menu
    }

    private func menuIcon() -> NSImage? {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        for resource in ["MenuIcon", "MenuIcon@2x"] {
            if let url = Bundle.main.url(forResource: resource, withExtension: "png"),
               let data = try? Data(contentsOf: url),
               let representation = NSBitmapImageRep(data: data) {
                representation.size = size
                image.addRepresentation(representation)
            }
        }
        if image.representations.isEmpty {
            let fallback = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Ashley VPN")
            fallback?.isTemplate = true
            return fallback
        }
        image.accessibilityDescription = "Ashley VPN"
        return image
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func connect() { run("connect") }
    @objc private func disconnect() { run("disconnect") }
    @objc private func quit() { NSApp.terminate(nil) }

    private func run(_ action: String) {
        guard let command = Bundle.main.url(forResource: action, withExtension: "command") else {
            report("安装内容不完整，请重新运行 install.sh。")
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in self.report("无法打开终端。\(error.localizedDescription)") }
            }
        }
    }

    private func report(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ashley VPN"
        alert.informativeText = message
        alert.runModal()
    }
}

@main
struct Main {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AshleyVPN()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
