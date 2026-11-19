import AppKit
import ApplicationServices

enum GlobalProtectConnect {
    private static let bundleID = "com.paloaltonetworks.GlobalProtect.client"
    private static let connectTitles: Set<String> = ["Connect", "连接", "連線", "連接"]

    static func pressConnect(promptForAccess: Bool) -> Int32 {
        let trusted = promptForAccess
            ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            : AXIsProcessTrusted()
        guard trusted else { return 3 }
        guard let client = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: {
            $0.executableURL?.path == "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"
        }) else { return 4 }

        let application = AXUIElementCreateApplication(client.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)

        let deadline = ProcessInfo.processInfo.systemUptime + 3
        if pressVisibleConnect(in: application, before: deadline) { return 0 }
        guard let menuBar = attribute(application, kAXExtrasMenuBarAttribute) as? [AXUIElement]
                ?? extrasMenuBarChildren(application),
              menuBar.count == 1,
              attribute(menuBar[0], kAXRoleAttribute) as? String == kAXMenuBarItemRole,
              ProcessInfo.processInfo.systemUptime < deadline,
              AXUIElementPerformAction(menuBar[0], kAXPressAction as CFString) == .success else { return 4 }

        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            if pressVisibleConnect(in: application, before: deadline) { return 0 }
        }
        return 4
    }

    private static func extrasMenuBarChildren(_ application: AXUIElement) -> [AXUIElement]? {
        guard let value = attribute(application, kAXExtrasMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let menuBar = value as! AXUIElement
        if attribute(menuBar, kAXRoleAttribute) as? String == kAXMenuBarItemRole { return [menuBar] }
        return elements(menuBar, kAXChildrenAttribute)
    }

    private static func pressVisibleConnect(in application: AXUIElement, before deadline: TimeInterval) -> Bool {
        let windows = elements(application, kAXWindowsAttribute)
        guard !windows.contains(where: { attribute($0, kAXModalAttribute) as? Bool == true }) else { return false }
        // Search the status panel only, skipping authentication web views and modal sheets.
        var candidates = windows + elements(application, kAXChildrenAttribute).filter {
            attribute($0, kAXRoleAttribute) as? String == kAXPopoverRole
        }
        var visited = 0
        while !candidates.isEmpty && visited < 80 && ProcessInfo.processInfo.systemUptime < deadline {
            let element = candidates.removeFirst()
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            switch role {
            case kAXButtonRole:
                let title = (attribute(element, kAXTitleAttribute) as? String)
                    ?? (attribute(element, kAXDescriptionAttribute) as? String)
                if let title, connectTitles.contains(title),
                   attribute(element, kAXEnabledAttribute) as? Bool == true,
                   AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    return true
                }
            case kAXWindowRole, kAXPopoverRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole:
                candidates.append(contentsOf: elements(element, kAXChildrenAttribute))
            default:
                break
            }
        }
        return false
    }

    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
