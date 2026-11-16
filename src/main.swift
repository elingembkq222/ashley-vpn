import AppKit

@MainActor
final class AshleyVPN: NSObject, NSApplicationDelegate {
    private enum VPNState: String {
        case stopped, running, connected
    }
    private enum Cancellation {
        case requested, sending, sent
    }

    private var item: NSStatusItem?
    private var orb: FloatingOrb?
    private lazy var connectedMenuIcon = menuIcon(named: "MenuIcon")
    private lazy var disabledMenuIcon = menuIcon(named: "MenuIconDisabled")
    private lazy var connectedOrb = resourceImage("FloatingIcon")
    private lazy var disabledOrb = resourceImage("FloatingIconDisabled")
    private var state: VPNState = .stopped
    private var busy = false
    private var pendingUntil: TimeInterval?
    private var cancellation: Cancellation?
    private var cancellationTarget: String?
    private var activeOperation: String?
    private var readingStatus = false
    private var statusTimer: Timer?
    private var animationTimer: Timer?
    private var animationStarted: TimeInterval = 0
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var isTransitioning: Bool { busy || pendingUntil != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.imagePosition = .imageOnly
        }

        if let image = disabledOrb {
            let orb = FloatingOrb(image: image) { [weak self] in self?.toggleFromDesktop() }
            self.orb = orb
            orb.show()
        }
        item.menu = makeMenu()
        updateDisplay()
        refreshStatus()
        statusTimer = makeTimer(interval: 1.5) { [weak self] in self?.refreshStatus() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        orb?.recoverOffscreenPosition()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        addItem("开启 VPN", action: #selector(connect), to: menu)
        addItem("关闭 VPN", action: #selector(disconnect), to: menu)
        menu.addItem(.separator())
        if let orb {
            addItem(orb.isVisible ? "隐藏桌面图标" : "显示桌面图标", action: #selector(toggleOrb), to: menu)
        }
        addItem("退出 Ashley VPN 图标", action: #selector(quit), to: menu)
        return menu
    }

    private func resourceImage(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    private func menuIcon(named name: String) -> NSImage? {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        for resource in [name, name + "@2x"] {
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

    private func makeTimer(interval: TimeInterval, action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func runMonitor(_ arguments: [String], completion: @escaping @MainActor (Int32, String) -> Void) {
        guard let runner = Bundle.main.url(forResource: "run-vpn", withExtension: "zsh") else {
            completion(-1, "")
            return
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", runner.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { child in
            let raw = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in completion(child.terminationStatus, raw) }
        }
        do {
            try process.run()
        } catch {
            completion(-1, "")
        }
    }

    private func refreshStatus() {
        guard !readingStatus else { return }
        readingStatus = true
        runMonitor(["status"]) { [weak self] code, raw in
            guard let self else { return }
            self.readingStatus = false
            let fields = raw.split(whereSeparator: \.isWhitespace)
            if code == 0, fields.count == 3, let next = VPNState(rawValue: String(fields[1])) {
                self.state = next
                self.busy = fields[0] == "busy"
                self.activeOperation = self.busy && UUID(uuidString: String(fields[2])) != nil ? String(fields[2]) : nil
            }
            if self.busy || self.uptime >= (self.pendingUntil ?? .infinity) {
                self.pendingUntil = nil
            }
            if !self.isTransitioning ||
                (self.activeOperation != nil && self.cancellationTarget != nil && self.activeOperation != self.cancellationTarget) {
                self.cancellation = nil
                self.cancellationTarget = nil
            }
            self.updateDisplay()
            self.cancelWhenReady()
        }
    }

    private func toggleFromDesktop() {
        if isTransitioning {
            guard cancellation == nil else { return }
            cancellation = .requested
            cancellationTarget = activeOperation
            updateDisplay()
            cancelWhenReady()
        } else {
            run("toggle")
        }
    }

    private func cancelWhenReady() {
        guard busy, cancellation == .requested, let activeOperation else { return }
        let target = cancellationTarget ?? activeOperation
        guard target == activeOperation else { return }
        cancellationTarget = target
        cancellation = .sending
        runMonitor(["cancel", target]) { [weak self] code, _ in
            guard let self, self.cancellation == .sending, self.cancellationTarget == target else { return }
            switch code {
            case 0:
                self.cancellation = .sent
                self.refreshStatus()
            case 3:
                self.cancellation = .requested
            default:
                self.cancellation = nil
                self.cancellationTarget = nil
                self.updateDisplay()
                self.report("无法中止这次操作，请在它的终端窗口按 Ctrl+C。")
            }
        }
    }

    private func updateDisplay() {
        if isTransitioning && animationTimer == nil {
            animationStarted = uptime
            animationTimer = makeTimer(interval: 1 / 24) { [weak self] in self?.drawIcons() }
        } else if !isTransitioning {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        drawIcons()
    }

    private func drawIcons() {
        let connected = state == .connected
        let phase = isTransitioning ? ((uptime - animationStarted) / 1.5).truncatingRemainder(dividingBy: 1) : nil
        let hint: String
        if cancellation != nil {
            hint = "正在取消本次 VPN 操作"
        } else if isTransitioning {
            hint = "正在切换集团 VPN，单击桌面图标取消"
        } else {
            switch state {
            case .connected: hint = "集团 VPN 已连接，单击桌面图标关闭"
            case .running: hint = "GlobalProtect 正在运行，单击桌面图标关闭"
            case .stopped: hint = "集团 VPN 已关闭，单击桌面图标开启"
            }
        }
        if let base = connected ? connectedMenuIcon : disabledMenuIcon {
            let icon = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                OrbitalGlow.draw(in: rect, inset: 0, phase: phase)
                return true
            }
            icon.accessibilityDescription = "Ashley VPN"
            item?.button?.image = icon
            item?.button?.toolTip = hint
        }
        if let image = connected ? connectedOrb : disabledOrb {
            orb?.update(image: image, hint: hint, phase: phase)
        }
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func connect() { run("connect") }
    @objc private func disconnect() { run("disconnect") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleOrb() {
        guard let orb else { return }
        if orb.isVisible { orb.hide() } else { orb.show() }
        item?.menu = makeMenu()
    }

    private func run(_ action: String) {
        guard !isTransitioning else { return }
        guard let runner = Bundle.main.url(forResource: "run-vpn", withExtension: "zsh") else {
            report("安装内容不完整，请重新运行 install.sh。")
            return
        }
        let session: TerminalSession
        do {
            session = try TerminalSession(runner: runner, action: action)
        } catch {
            report("无法创建本次操作的终端会话。\(error.localizedDescription)")
            return
        }
        pendingUntil = uptime + 4
        updateDisplay()
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([session.profile], withApplicationAt: terminal, configuration: .init()) { _, error in
            Task { @MainActor in
                if let error {
                    try? FileManager.default.removeItem(at: session.directory)
                    self.pendingUntil = nil
                    self.updateDisplay()
                    self.report("无法打开终端。\(error.localizedDescription)")
                } else {
                    self.refreshStatus()
                }
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
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--scan-wifi" {
            WiFiScan.run(interfaceName: arguments[2], outputPath: arguments[3])
            return
        }
        let delegate = AshleyVPN()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
