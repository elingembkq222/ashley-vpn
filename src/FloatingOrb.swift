import AppKit

@MainActor
final class FloatingOrb: NSObject, NSWindowDelegate {
    enum StatusTone {
        case working, success, warning, neutral
    }

    private static let size = NSSize(width: 104, height: 104)
    private static let frameKey = "AshleyVPNFloatingOrb"
    private let panel: NSPanel
    private let view: OrbView
    private let statusPanel: NSPanel
    private let statusPill = StatusPill(frame: .zero)

    var isVisible: Bool { panel.isVisible }

    init(image: NSImage, toggle: @escaping () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        view = OrbView(image: image, toggle: toggle)
        statusPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

        statusPill.setAccessibilityElement(true)
        statusPill.setAccessibilityRole(.staticText)
        statusPanel.contentView = statusPill
        statusPanel.isOpaque = false
        statusPanel.backgroundColor = .clear
        statusPanel.hasShadow = true
        statusPanel.ignoresMouseEvents = true
        statusPanel.hidesOnDeactivate = false
        statusPanel.collectionBehavior = panel.collectionBehavior
        statusPanel.level = panel.level

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
        statusPanel.orderOut(nil)
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

    func showStatus(_ text: String, time: String? = nil, isCountdown: Bool = false,
                    step: String? = nil, phase: Double? = nil, tone: StatusTone = .neutral) {
        guard isVisible, !text.isEmpty else {
            if statusPanel.isVisible { statusPanel.orderOut(nil) }
            return
        }
        let content = StatusPill.Content(text: text, time: time, isCountdown: isCountdown, step: step, tone: tone)
        let changed = statusPill.content != content
        statusPill.content = content
        statusPill.phase = phase
        statusPill.needsDisplay = true
        if changed {
            statusPill.setAccessibilityLabel(content.accessibilityLabel)
        }
        if changed || !statusPanel.isVisible {
            positionStatus()
            statusPanel.orderFrontRegardless()
        }
    }

    private func positionStatus() {
        guard let bounds = panel.screen?.visibleFrame else { return }
        let frame = panel.frame
        let maxWidth = min(460, bounds.width - 16)
        statusPanel.setContentSize(NSSize(width: min(statusPill.preferredWidth, maxWidth), height: StatusPill.height))
        let size = statusPanel.frame.size
        let x = min(max(frame.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        let y = frame.maxY + size.height + 14 <= bounds.maxY ? frame.maxY + 6 : frame.minY - size.height - 6
        statusPanel.setFrameOrigin(NSPoint(x: x, y: max(bounds.minY + 8, y)))
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
        if statusPanel.isVisible { positionStatus() }
    }

    func windowDidMove(_ notification: Notification) {
        panel.saveFrame(usingName: Self.frameKey)
        if statusPanel.isVisible { positionStatus() }
    }
}

@MainActor
private final class StatusPill: NSView {
    struct Content: Equatable {
        let text: String
        let time: String?
        let isCountdown: Bool
        let step: String?
        let tone: FloatingOrb.StatusTone

        var accessibilityLabel: String {
            let duration = time.map { (isCountdown ? "剩余时间 " : "已用时间 ") + $0 }
            return [text, duration, step].compactMap { $0 }.joined(separator: "，")
        }
    }

    static let height: CGFloat = 44
    private static let messageInset: CGFloat = 38
    private static let trailingInset: CGFloat = 10
    private static let gap: CGFloat = 10
    var content = Content(text: "", time: nil, isCountdown: false, step: nil, tone: .neutral)
    var phase: Double?

    private let textFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let stepFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let foreground = NSColor(white: 0.97, alpha: 1)
    private let muted = NSColor(white: 0.70, alpha: 1)

    var preferredWidth: CGFloat {
        Self.messageInset + textWidth(content.text, font: textFont) + Self.trailingInset
            + (content.time == nil ? 0 : textWidth(content.time, font: timeFont) + Self.gap)
            + (content.step == nil ? 0 : textWidth(content.step, font: stepFont) + 36)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(srgbRed: 0.12, green: 0.12, blue: 0.115, alpha: 1).setFill()
        body.fill()
        NSColor(white: 0.23, alpha: 1).setStroke()
        body.lineWidth = 1
        body.stroke()
        drawIndicator()

        var right = bounds.maxX - Self.trailingInset
        if let step = content.step {
            let width = textWidth(step, font: stepFont)
            let badge = NSRect(x: right - width - 20, y: bounds.midY - 15, width: width + 20, height: 30)
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 15, yRadius: 15).fill()
            drawText(step, at: badge.minX + 10, width: width, font: stepFont, color: foreground)
            right = badge.minX - 8
            NSColor(white: 0.25, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: right, y: bounds.midY - 8, width: 1, height: 16)).fill()
            right -= 8
        }
        if let time = content.time {
            let width = textWidth(time, font: timeFont)
            drawText(time, at: right - width, width: width, font: timeFont, color: muted)
            right -= width + Self.gap
        }
        drawText(content.text, at: Self.messageInset, width: max(0, right - Self.messageInset),
                 font: textFont, color: foreground)
    }

    private func drawIndicator() {
        let center = NSPoint(x: 22, y: bounds.midY)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        ring.lineWidth = 2
        let green = NSColor(srgbRed: 0.39, green: 0.72, blue: 0.54, alpha: 1)
        if content.tone == .working {
            green.withAlphaComponent(0.24).setStroke()
            ring.stroke()
            let angle = 90 - (phase ?? 0) * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 7, startAngle: angle, endAngle: angle - 115, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            green.setStroke()
            arc.stroke()
            return
        }
        let color: NSColor
        let mark: String
        switch content.tone {
        case .success: (color, mark) = (green, "✓")
        case .warning: (color, mark) = (NSColor(srgbRed: 0.94, green: 0.65, blue: 0.34, alpha: 1), "!")
        default: (color, mark) = (muted, "–")
        }
        color.withAlphaComponent(0.55).setStroke()
        ring.stroke()
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let width = textWidth(mark, font: font)
        drawText(mark, at: center.x - width / 2, width: width, font: font, color: color)
    }

    private func textWidth(_ text: String?, font: NSFont) -> CGFloat {
        guard let text else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    private func drawText(_ text: String, at x: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let value = text as NSString
        let height = ceil(value.size(withAttributes: [.font: font]).height)
        let rect = NSRect(x: x, y: floor(bounds.midY - height / 2), width: width, height: height)
        value.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
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
