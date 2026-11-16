import AppKit

@MainActor
final class FloatingOrb: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 104, height: 104)
    private static let frameKey = "AshleyVPNFloatingOrb"
    private let panel: NSPanel
    private let view: OrbView

    var isVisible: Bool { panel.isVisible }

    init(image: NSImage, toggle: @escaping () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        view = OrbView(image: image, toggle: toggle)
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
        panel.contentView = view

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

    func update(image: NSImage, hint: String, phase: Double?) {
        view.image = image
        view.phase = phase
        if view.toolTip != hint {
            view.toolTip = hint
            view.setAccessibilityHelp(hint)
        }
        view.needsDisplay = true
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
    var image: NSImage
    var phase: Double?
    private let toggle: () -> Void
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var didDrag = false

    init(image: NSImage, toggle: @escaping () -> Void) {
        self.image = image
        self.toggle = toggle
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ashley VPN 桌面悬浮图标")
        toolTip = "Ashley VPN"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        OrbitalGlow.draw(in: bounds, inset: 32, phase: phase)
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
        if !didDrag && bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

}

@MainActor
enum OrbitalGlow {
    static func draw(in rect: NSRect, inset: CGFloat, phase: Double?) {
        let unit = rect.width / (256 + 2 * inset)
        let rotation = -22.0 * .pi / 180
        let position = phase ?? 0
        let pulse = phase.map { 0.78 + 0.22 * cos($0 * 2 * .pi) } ?? 1
        let trail = phase == nil ? 0 : 3
        for index in (0...trail).reversed() {
            let angle = (position - Double(index) * 0.025) * 2 * .pi
            let x = 124 * cos(angle)
            let y = 38 * sin(angle)
            let center = NSPoint(
                x: rect.midX + (x * cos(rotation) - y * sin(rotation)) * unit,
                y: rect.midY - (x * sin(rotation) + y * cos(rotation)) * unit
            )
            let alpha = pulse * pow(0.37, Double(index))
            let radius = (phase == nil ? 11 : 15) * unit
            let highlight = NSColor(srgbRed: 1, green: 0.69, blue: 0.29, alpha: alpha)
            NSGradient(starting: highlight.withAlphaComponent(alpha * 0.6),
                       ending: highlight.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
            if index == 0 {
                let core = 5 * unit
                highlight.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - core, y: center.y - core,
                                          width: 2 * core, height: 2 * core)).fill()
            }
        }
    }
}
