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
    private var menuStatus: NSMenuItem?
    private var menuCancel: NSMenuItem?
    private var menuCodexProxy: NSMenuItem?
    private let defaults = UserDefaults.standard
    private var selectedRoute: CodexProxyStatus.Selection?
    private var proxyRoutes: [CodexProxyStatus.Route] = []
    private var proxyCheck: Task<Void, Never>?
    private var proxyTimer: Timer?
    private let routing = TransparentRouting()
    private var switchingCodexRoute = false
    private var healthCheck: Task<Void, Never>?
    private var failedProxyCheck: URL?
    private var codexRouteStatus: String?
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
    private var hasVPNStatus = false
    private var statusTimer: Timer?
    private var terminalInputActive = false
    private var animationTimer: Timer?
    private var animationStarted: TimeInterval = 0
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var isTransitioning: Bool { busy || workerRunning || pendingUntil != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = defaults.data(forKey: "codexRoute") {
            selectedRoute = try? JSONDecoder().decode(CodexProxyStatus.Selection.self, from: data)
            if routing.usesDomainRules, selectedRoute?.id.hasPrefix("vpn:") == true {
                selectedRoute = nil
                defaults.removeObject(forKey: "codexRoute")
            }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.imagePosition = .imageOnly
        }

        if let image = disabledOrb {
            let orb = FloatingOrb(image: image, toggle: { [weak self] in self?.toggleFromDesktop() },
                                  quit: { [weak self] in self?.confirmOrbExit() })
            self.orb = orb
            orb.show()
        }
        item.menu = makeMenu()
        updateDisplay()
        refreshStatus()
        refreshCodexProxy()
        proxyTimer = makeTimer(interval: 60) { [weak self] in self?.refreshCodexProxy() }
        setStatusCadence(terminalInputActive: false)
        applyRoute()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        orb?.recoverOffscreenPosition()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: "Ashley VPN", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menuStatus = status
        menu.addItem(.separator())
        addItem("连接 VPN", action: #selector(connect), to: menu)
        addItem("断开 VPN", action: #selector(disconnect), to: menu)
        menuCancel = addItem("取消操作", action: #selector(cancelFromMenu), to: menu)
        let proxy = NSMenuItem(title: routing.usesDomainRules ? "OpenAI 域名代理" : "Codex 流量", action: nil, keyEquivalent: "")
        menu.addItem(proxy)
        menuCodexProxy = proxy
        updateProxyMenu()
        menu.addItem(.separator())
        if let orb {
            addItem(orb.isVisible ? "隐藏浮标" : "显示浮标", action: #selector(toggleOrb), to: menu)
        }
        addItem("退出", action: #selector(confirmOrbExit), to: menu)
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
            let status = child.terminationStatus
            Task { @MainActor in completion(status, raw) }
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
                self.hasVPNStatus = true
                self.state = next
                self.busy = fields[0] == "busy"
                self.activeOperation = self.busy && UUID(uuidString: String(fields[2])) != nil ? String(fields[2]) : nil
                self.progress = self.busy && lines.count > 1 ? lines[1] : ""
                self.progressStep = self.busy && lines.count > 3 && !lines[3].isEmpty ? lines[3] : nil
                self.progressRemaining = self.busy && lines.count > 4 ? Int(lines[4]) : nil
                self.setStatusCadence(terminalInputActive: self.activeOperation != nil && lines.count > 2 && !lines[2].isEmpty)
                if let token = self.activeOperation, lines.count > 2,
                   self.cancellation == nil || lines[2].hasPrefix("cancel-stop-system ") {
                    self.openInput(lines[2], token: token)
                }
            } else {
                self.hasVPNStatus = false
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
            if self.selectedRoute != nil && !self.switchingCodexRoute && self.routing.networkServiceChanged {
                self.applyRoute()
            }
            let status = self.routing.status
            if status != self.codexRouteStatus {
                self.codexRouteStatus = status
                self.updateProxyMenu()
            }
        }
    }

    private func refreshCodexProxy() {
        guard proxyCheck == nil else { return }
        let savedProxy = selectedRoute?.proxyURL
        proxyCheck = Task { [weak self] in
            let discovered = await Task.detached(priority: .utility) {
                CodexProxyStatus.routes(savedProxy: savedProxy)
            }.value
            guard !Task.isCancelled, let self else { return }
            let routes = discovered.filter {
                if case .localProxy = $0.kind { return true }
                return !self.routing.usesDomainRules
            }
            self.proxyCheck = nil
            if routes == self.proxyRoutes {
                if self.routing.needsReconnect { self.applyRoute() }
                else { self.checkSelectedProxy() }
                return
            }
            let previous = self.proxyRoutes.first { $0.id == self.selectedRoute?.id }
            self.proxyRoutes = routes
            let current = routes.first { $0.id == self.selectedRoute?.id }
            if previous != current || self.routing.needsReconnect { self.applyRoute() }
            else { self.checkSelectedProxy() }
            self.updateProxyMenu()
        }
    }

    private func updateProxyMenu() {
        guard let menuCodexProxy else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let codexRouteStatus {
            let failed = routing.policyActive && failedProxyCheck != nil && failedProxyCheck == resolvedSelection?.proxyURL
            let status = NSMenuItem(title: failed ? "所选代理未通过 Codex 连通检查" : codexRouteStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }
        let none = addItem("无", action: #selector(selectCodexProxy(_:)), to: menu)
        none.state = selectedRoute == nil ? .on : .off
        none.toolTip = "使用 Codex 和 macOS 的默认网络设置"
        none.isEnabled = !switchingCodexRoute

        if !proxyRoutes.isEmpty { menu.addItem(.separator()) }
        for route in proxyRoutes {
            let title: String
            switch route.kind {
            case .localProxy:
                title = route.name
            case .systemVPN(let available):
                title = "\(route.name) · \(available ? "系统 VPN" : "当前不可用")"
            case .runningClient(let supportsProxy):
                title = "\(route.name) · \(supportsProxy ? "等待代理端口" : "已启动")"
            }
            let item = addItem(title, action: #selector(selectCodexProxy(_:)), to: menu)
            item.representedObject = route.id
            item.isEnabled = !switchingCodexRoute
            item.state = route.id == selectedRoute?.id ? .on : .off
            if case .localProxy = route.kind {
                item.toolTip = routing.usesDomainRules ? "ChatGPT、Codex 和 OpenAI 域名通过此代理连接" : "Codex 通过此客户端的本地代理连接"
            } else if case .runningClient(true) = route.kind {
                item.toolTip = "可提前选择，代理就绪后 Codex 的新连接将使用此线路"
            } else if case .runningClient(false) = route.kind {
                item.isEnabled = false
                item.toolTip = "等待客户端提供可识别的代理或 VPN 隧道"
            } else if case .systemVPN(false) = route.kind {
                item.isEnabled = false
                item.toolTip = "请在当前网络位置启用此 VPN"
            }
        }
        if let selectedRoute, (!routing.usesDomainRules || selectedRoute.id.hasPrefix("proxy:")), !proxyRoutes.contains(where: { $0.id == selectedRoute.id }) {
            let unavailable = NSMenuItem(title: "\(selectedRoute.name) · 当前不可用", action: nil, keyEquivalent: "")
            unavailable.state = .on
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }
        menuCodexProxy.submenu = menu
    }

    @objc private func selectCodexProxy(_ item: NSMenuItem) {
        guard !switchingCodexRoute, item.isEnabled else { return }
        if let id = item.representedObject as? String {
            guard let route = proxyRoutes.first(where: { $0.id == id }) else { return }
            let selection = CodexProxyStatus.Selection(route)
            guard let data = try? JSONEncoder().encode(selection) else { return }
            defaults.set(data, forKey: "codexRoute")
            selectedRoute = selection
        } else {
            defaults.removeObject(forKey: "codexRoute")
            selectedRoute = nil
        }
        applyRoute()
    }

    private var resolvedSelection: CodexProxyStatus.Selection? {
        guard let selectedRoute, let route = proxyRoutes.first(where: { $0.id == selectedRoute.id }) else { return selectedRoute }
        return CodexProxyStatus.Selection(route)
    }

    private func applyRoute() {
        guard !switchingCodexRoute else { return }
        let requested = resolvedSelection
        switchingCodexRoute = true
        updateProxyMenu()
        Task {
            await routing.apply(requested)
            checkSelectedProxy()
            switchingCodexRoute = false
            codexRouteStatus = routing.status
            updateProxyMenu()
            if requested?.proxyURL != resolvedSelection?.proxyURL { applyRoute() }
        }
    }

    private func checkSelectedProxy() {
        healthCheck?.cancel()
        guard routing.policyActive, let selection = resolvedSelection, let url = selection.proxyURL else {
            failedProxyCheck = nil
            return
        }
        healthCheck = Task {
            let reachable = await Task.detached(priority: .utility) {
                CodexProxyStatus.localProxyRoute(url)?.id == selection.id && CodexProxyStatus.proxyIsReachable(url)
            }.value
            guard !Task.isCancelled, resolvedSelection?.proxyURL == url else { return }
            failedProxyCheck = reachable ? nil : url
            updateProxyMenu()
        }
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
            statusText = progress.isEmpty ? "正在取消本次 VPN 操作" : progress
        } else if isTransitioning {
            statusText = progress.isEmpty ? "正在切换集团 VPN" : progress
        } else if uptime < feedbackUntil {
            statusText = feedback
        } else {
            switch state {
            case .connected: statusText = "集团 VPN 已连接，单击桌面图标关闭"
            case .running: statusText = "GlobalProtect 正在运行，单击桌面图标连接"
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
        let menuTitle: String
        if cancellation != nil {
            menuTitle = "取消中"
        } else if isTransitioning {
            menuTitle = "切换中"
        } else {
            switch state {
            case .connected: menuTitle = "VPN 已连接"
            case .running: menuTitle = "VPN 运行中"
            case .stopped: menuTitle = "VPN 已关闭"
            }
        }
        if menuStatus?.title != menuTitle { menuStatus?.title = menuTitle }
        menuCancel?.isHidden = !isTransitioning || cancellation != nil
        if let image = connected ? connectedOrb : disabledOrb {
            orb?.update(image: image, hint: hint, phase: phase)
        }
        orb?.setExitBubbleAvailable(hasVPNStatus && !isTransitioning)
        if isTransitioning {
            let seconds = max(0, countdown ?? Int(elapsed))
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let step = cancellation == nil ? progressStep.map { "步骤 \($0)" } : nil
            orb?.showStatus(statusText, time: time, isCountdown: countdown != nil,
                            step: step, phase: phase, tone: .working)
        } else if switchingCodexRoute {
            orb?.showStatus(codexRouteStatus ?? "正在切换 Codex 线路", tone: .working)
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
    private func quit() { NSApp.terminate(nil) }

    @objc private func confirmOrbExit() {
        guard hasVPNStatus, !isTransitioning else { return }
        run("disconnect-keep-network", quitWhenFinished: true)
    }

    @objc private func toggleOrb() {
        guard let orb else { return }
        if orb.isVisible { orb.hide() } else { orb.show() }
        item?.menu = makeMenu()
        drawIcons()
    }

    private func run(_ action: String, quitWhenFinished: Bool = false) {
        guard !isTransitioning else { return }
        let disconnecting = action == "disconnect" || action == "disconnect-keep-network" ||
            (action == "toggle" && state == .connected)
        workerRunning = true
        lastInput = nil
        pendingUntil = uptime + 4
        updateDisplay()
        runMonitor([action], worker: true) { [weak self] code, raw in
            guard let self else { return }
            if disconnecting && code == 0 && quitWhenFinished && self.cancellation == nil { self.quit(); return }
            self.workerRunning = false
            self.pendingUntil = nil
            self.progress = ""
            self.progressStep = nil
            self.progressRemaining = nil
            let cancelled = code == 130
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
              ["connect-wifi", "connect-wifi-reset", "disconnect-wifi", "stop-system", "cancel-stop-system", "start-system"].contains(parts[0]),
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
        if arguments == [arguments[0], "--remove-domain-routing"] {
            do { try DomainRouting.apply(nil) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
            return
        }
        if arguments == [arguments[0], "--remove-routing"] {
            Task { @MainActor in
                do { try await TransparentRouting().uninstall(); exit(0) }
                catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
            }
            RunLoop.main.run()
            return
        }
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
        if arguments.count == 3, arguments[1] == "--connect-globalprotect" {
            exit(GlobalProtectConnect.pressConnect(promptForAccess: arguments[2] == "prompt"))
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
