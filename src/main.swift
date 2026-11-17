import AppKit

@MainActor
final class AshleyVPN: NSObject, NSApplicationDelegate {
    private enum VPNState: String {
        case stopped, running, connected
    }
    private enum Cancellation {
        case requested, sending, sent
    }
    private struct ProxyApps: Equatable {
        let codex: pid_t
        let libCyber: pid_t
    }

    private var item: NSStatusItem?
    private var menuStatus: NSMenuItem?
    private var menuCancel: NSMenuItem?
    private var menuCodexProxy: NSMenuItem?
    private var proxyApps: ProxyApps?
    private var proxyStatus: String?
    private var proxyCheck: Task<Void, Never>?
    private var lastProxyCheck: TimeInterval?
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
    private var workerRunning = false
    private var progress = ""
    private var progressStep: String?
    private var progressRemaining: Int?
    private var lastInput: String?
    private var feedback = ""
    private var feedbackTone: FloatingOrb.StatusTone = .neutral
    private var feedbackUntil: TimeInterval = 0
    private var readingStatus = false
    private var statusTimer: Timer?
    private var terminalInputActive = false
    private var animationTimer: Timer?
    private var animationStarted: TimeInterval = 0
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var isTransitioning: Bool { busy || workerRunning || pendingUntil != nil }

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
        setStatusCadence(terminalInputActive: false)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        orb?.recoverOffscreenPosition()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Ashley VPN", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menuStatus = status
        let proxy = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(proxy)
        menuCodexProxy = proxy
        updateProxyMenu()
        menu.addItem(.separator())
        addItem("开启 VPN", action: #selector(connect), to: menu)
        addItem("关闭 VPN", action: #selector(disconnect), to: menu)
        menuCancel = addItem("取消本次操作", action: #selector(cancelFromMenu), to: menu)
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

    private func setStatusCadence(terminalInputActive: Bool) {
        guard statusTimer == nil || self.terminalInputActive != terminalInputActive else { return }
        self.terminalInputActive = terminalInputActive
        statusTimer?.invalidate()
        statusTimer = makeTimer(interval: terminalInputActive ? 0.4 : 1.5) { [weak self] in self?.refreshStatus() }
    }

    private func runMonitor(_ arguments: [String], worker: Bool = false,
                            completion: @escaping @MainActor (Int32, String) -> Void) {
        guard let runner = Bundle.main.url(forResource: "run-vpn", withExtension: "zsh") else {
            completion(-1, "")
            return
        }
        let process = Process()
        let output = Pipe()
        if worker {
            guard let executable = Bundle.main.executableURL else {
                completion(-1, "")
                return
            }
            process.executableURL = executable
            process.arguments = ["--vpn-worker"] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", runner.path] + arguments
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = worker ? output : FileHandle.nullDevice
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
            let lines = raw.components(separatedBy: "\n")
            let fields = (lines.first ?? "").split(whereSeparator: \.isWhitespace)
            if code == 0, fields.count == 3, let next = VPNState(rawValue: String(fields[1])) {
                self.state = next
                self.busy = fields[0] == "busy"
                self.activeOperation = self.busy && UUID(uuidString: String(fields[2])) != nil ? String(fields[2]) : nil
                self.progress = self.busy && lines.count > 1 ? lines[1] : ""
                self.progressStep = self.busy && lines.count > 3 && !lines[3].isEmpty ? lines[3] : nil
                self.progressRemaining = self.busy && lines.count > 4 ? Int(lines[4]) : nil
                self.setStatusCadence(terminalInputActive: self.activeOperation != nil && lines.count > 2 && !lines[2].isEmpty)
                if let token = self.activeOperation, lines.count > 2, self.cancellation == nil {
                    self.openInput(lines[2], token: token)
                }
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
            self.refreshCodexProxy()
        }
    }

    private func refreshCodexProxy() {
        guard state == .connected, !isTransitioning,
              let codex = NSRunningApplication.runningApplications(withBundleIdentifier: CodexProxyStatus.codexIdentifier).first,
              let libCyber = NSRunningApplication.runningApplications(withBundleIdentifier: CodexProxyStatus.libCyberIdentifier).first,
              let codexURL = codex.bundleURL, let libCyberURL = libCyber.bundleURL else {
            if proxyApps != nil { resetProxyCheck() }
            return
        }

        let apps = ProxyApps(codex: codex.processIdentifier, libCyber: libCyber.processIdentifier)
        if apps != proxyApps {
            resetProxyCheck()
            proxyApps = apps
            proxyStatus = "正在检查 Codex 与 LibCyber"
            updateProxyMenu()
        }
        guard proxyCheck == nil, uptime - (lastProxyCheck ?? -.infinity) >= 5 else { return }
        lastProxyCheck = uptime
        proxyCheck = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                CodexProxyStatus.check(codex: codexURL, libCyber: libCyberURL)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.proxyCheck = nil
            self.proxyStatus = status.rawValue
            self.updateProxyMenu()
        }
    }

    private func resetProxyCheck() {
        proxyCheck?.cancel()
        proxyCheck = nil
        proxyApps = nil
        proxyStatus = nil
        lastProxyCheck = nil
        updateProxyMenu()
    }

    private func updateProxyMenu() {
        menuCodexProxy?.title = proxyStatus ?? ""
        menuCodexProxy?.isHidden = proxyStatus == nil
    }

    private func toggleFromDesktop() {
        if isTransitioning {
            cancelFromMenu()
        } else {
            run("toggle")
        }
    }

    @objc private func cancelFromMenu() {
        guard isTransitioning, cancellation == nil else { return }
        cancellation = .requested
        cancellationTarget = activeOperation
        updateDisplay()
        cancelWhenReady()
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
                self.report("无法中止本次 VPN 操作。正在等待输入时，可以在终端按 Ctrl+C。")
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
        let elapsed = max(0, uptime - animationStarted)
        let phase = isTransitioning ? (elapsed / 1.5).truncatingRemainder(dividingBy: 1) : nil
        let statusText: String
        let countdown = isTransitioning && cancellation == nil ? progressRemaining : nil
        if cancellation != nil {
            statusText = "正在取消本次 VPN 操作"
        } else if isTransitioning {
            statusText = progress.isEmpty ? "正在切换集团 VPN" : progress
        } else if uptime < feedbackUntil {
            statusText = feedback
        } else {
            switch state {
            case .connected: statusText = "集团 VPN 已连接，单击桌面图标关闭"
            case .running: statusText = "GlobalProtect 正在运行，单击桌面图标关闭"
            case .stopped: statusText = "集团 VPN 已关闭，单击桌面图标开启"
            }
        }
        let hint = countdown.map { "\(statusText) · 最多再等 \($0) 秒" } ?? statusText
        if let base = connected ? connectedMenuIcon : disabledMenuIcon {
            let icon = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                if let phase {
                    let brightness = 0.4 + 0.6 * (1 + cos(phase * 2 * .pi)) / 2
                    NSColor.systemOrange.withAlphaComponent(brightness).setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
                }
                return true
            }
            icon.accessibilityDescription = "Ashley VPN"
            item?.button?.image = icon
            item?.button?.toolTip = hint
        }
        if menuStatus?.title != hint { menuStatus?.title = hint }
        menuCancel?.isHidden = !isTransitioning || cancellation != nil
        if let image = connected ? connectedOrb : disabledOrb {
            orb?.update(image: image, hint: hint, phase: phase)
        }
        if isTransitioning {
            let seconds = max(0, countdown ?? Int(elapsed))
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let step = cancellation == nil ? progressStep.map { "步骤 \($0)" } : nil
            orb?.showStatus(statusText, time: time, isCountdown: countdown != nil,
                            step: step, phase: phase, tone: .working)
        } else {
            orb?.showStatus(uptime < feedbackUntil ? feedback : "", tone: feedbackTone)
        }
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func connect() { run("connect") }
    @objc private func disconnect() { run("disconnect") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleOrb() {
        guard let orb else { return }
        if orb.isVisible { orb.hide() } else { orb.show() }
        item?.menu = makeMenu()
        drawIcons()
    }

    private func run(_ action: String) {
        guard !isTransitioning else { return }
        workerRunning = true
        lastInput = nil
        pendingUntil = uptime + 4
        updateDisplay()
        runMonitor([action], worker: true) { [weak self] code, raw in
            guard let self else { return }
            self.workerRunning = false
            self.pendingUntil = nil
            self.progress = ""
            self.progressStep = nil
            self.progressRemaining = nil
            let cancelled = code == 130 || (code != 0 && self.cancellation != nil)
            if code == 0 {
                self.feedback = raw.contains("VPN 已连接") ? "集团 VPN 已连接" : "集团 VPN 已关闭"
                self.feedbackTone = .success
            } else if cancelled {
                self.feedback = ""
                self.feedbackTone = .neutral
            } else {
                self.feedback = raw.split(whereSeparator: \.isNewline).last.map(String.init) ?? "VPN 操作未完成"
                self.feedbackTone = .warning
            }
            self.feedbackUntil = cancelled ? 0 : self.uptime + 5
            self.updateDisplay()
            self.refreshStatus()
        }
    }

    private func openInput(_ request: String, token: String) {
        let parts = request.split(separator: " ").map(String.init)
        guard parts.count == 2,
              ["connect-wifi", "connect-wifi-reset", "disconnect-wifi", "stop-system", "start-system"].contains(parts[0]),
              parts[1].hasPrefix("input.\(token)."),
              parts[1].range(of: #"^input\.[a-fA-F0-9-]+\.[a-zA-Z0-9]+$"#, options: .regularExpression) != nil,
              lastInput != parts[1],
              let runner = Bundle.main.url(forResource: "run-vpn", withExtension: "zsh") else { return }
        let result = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ashley VPN")
            .appendingPathComponent(parts[1]).appendingPathComponent("result")
        lastInput = parts[1]
        let session: TerminalSession
        do {
            session = try TerminalSession(runner: runner, arguments: ["input"] + parts)
        } catch {
            try? "1\n".write(to: result, atomically: true, encoding: .utf8)
            report("无法创建输入终端。\(error.localizedDescription)")
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([session.profile], withApplicationAt: terminal, configuration: .init()) { _, error in
            if let error {
                try? FileManager.default.removeItem(at: session.directory)
                try? "1\n".write(to: result, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    self.report("无法打开终端。\(error.localizedDescription)")
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
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--vpn-worker" {
            guard let runner = Bundle.main.url(forResource: "run-vpn", withExtension: "zsh"),
                  getpgrp() == getpid() || setpgid(0, 0) == 0 else { exit(1) }
            setenv("ASHLEY_VPN_BACKGROUND", "1", 1)
            let command = ["/bin/zsh", "-f", runner.path, arguments[2]]
            var argv = command.map { strdup($0) } + [nil]
            argv.withUnsafeMutableBufferPointer { arguments in
                guard let base = arguments.baseAddress else { return }
                _ = execv(command[0], base)
            }
            exit(1)
        }
        if arguments.count == 4, arguments[1] == "--scan-wifi" {
            WiFiScan.run(interfaceName: arguments[2], outputPath: arguments[3])
            return
        }
        let application = NSApplication.shared
        let delegate = AshleyVPN()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
