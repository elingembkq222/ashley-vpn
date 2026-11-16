import AppKit

@MainActor
final class FloatingOrb: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 104, height: 104)
    private static let frameKey = "AshleyVPNFloatingOrb"
    private let panel: NSPanel

    var isVisible: Bool { panel.isVisible }

    init(image: NSImage, menu: @escaping () -> NSMenu) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Ashley VPN 桌面悬浮图标"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.delegate = self
        panel.contentView = OrbView(image: image, menu: menu)

        if !panel.setFrameUsingName(Self.frameKey), let screen = NSScreen.main {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - Self.size.width - 20, y: bounds.minY + 20))
        }
        panel.setContentSize(Self.size)
        recoverOffscreenPosition()
    }

    func show() {
        recoverOffscreenPosition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func recoverOffscreenPosition() {
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) ?? NSScreen.main else {
            return
        }
        let bounds = screen.visibleFrame
        let origin = NSPoint(
            x: max(bounds.minX, min(frame.minX, bounds.maxX - frame.width)),
            y: max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        )
        if origin != frame.origin {
            panel.setFrameOrigin(origin)
        }
    }

    func windowDidMove(_ notification: Notification) {
        panel.saveFrame(usingName: Self.frameKey)
    }
}

@MainActor
private final class OrbView: NSView {
    private let image: NSImage
    private let makeMenu: () -> NSMenu
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var didDrag = false

    init(image: NSImage, menu: @escaping () -> NSMenu) {
        self.image = image
        makeMenu = menu
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ashley VPN 桌面悬浮图标")
        toolTip = "Ashley VPN"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        let x = point.x - mouseStart.x
        let y = point.y - mouseStart.y
        guard didDrag || abs(x) >= 3 || abs(y) >= 3 else { return }
        didDrag = true
        window?.setFrameOrigin(NSPoint(x: windowStart.x + x, y: windowStart.y + y))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag && bounds.contains(convert(event.locationInWindow, from: nil)) { showMenu() }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu() }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.maxY), in: self)
    }
}
