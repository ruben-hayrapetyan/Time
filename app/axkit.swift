// Accessibility helpers for reading and operating System Settings' Screen Time pages.
import AppKit
import ApplicationServices

let settingsBundleID = "com.apple.systempreferences"
let screenTimeURL = URL(string: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension")!

enum AX {
    static func trusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func str(_ el: AXUIElement, _ name: String) -> String {
        guard let v = attr(el, name) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute) }

    /// Everything a person would read on an element: title, description, value, identifier.
    static func label(_ el: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { str(el, $0) }.first { !$0.isEmpty } ?? ""
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return true }
        // Sidebar and list rows select instead of press.
        return AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func setValue(_ el: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString) == .success
    }

    static func walk(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 40, _ visit: (AXUIElement, Int) -> Bool) {
        guard depth <= maxDepth, visit(el, depth) else { return }
        for c in children(el) { walk(c, depth: depth + 1, maxDepth: maxDepth, visit) }
    }

    static func find(in root: AXUIElement, maxDepth: Int = 40, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        walk(root, maxDepth: maxDepth) { el, _ in
            if found != nil { return false }
            if match(el) { found = el; return false }
            return true
        }
        return found
    }

    static func findAll(in root: AXUIElement, maxDepth: Int = 40, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var out: [AXUIElement] = []
        walk(root, maxDepth: maxDepth) { el, _ in
            if match(el) { out.append(el) }
            return true
        }
        return out
    }

    static func dump(_ root: AXUIElement, maxDepth: Int = 40) -> String {
        var lines: [String] = []
        walk(root, maxDepth: maxDepth) { el, d in
            let r = role(el)
            if r == "AXOutline" && str(el, kAXDescriptionAttribute) == "Sidebar" { return false }
            var parts = [r]
            let sub = str(el, kAXSubroleAttribute)
            if !sub.isEmpty { parts.append("sub=\(sub)") }
            for (k, key) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("val", kAXValueAttribute), ("id", kAXIdentifierAttribute as String)] {
                let v = str(el, key)
                if !v.isEmpty { parts.append("\(k)=\(v.prefix(80))") }
            }
            let acts = actions(el).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
            if !acts.isEmpty { parts.append("[\(acts.joined(separator: ","))]") }
            lines.append(String(repeating: "  ", count: d) + parts.joined(separator: " | "))
            return lines.count < 6000
        }
        return lines.joined(separator: "\n")
    }
}

/// The System Settings app as an accessibility element, launching it if needed.
final class SettingsUI {
    var app: AXUIElement?

    func open(_ url: URL = screenTimeURL) {
        NSWorkspace.shared.open(url)
        for _ in 0..<40 {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first {
                app = AXUIElementCreateApplication(running.processIdentifier)
                if window != nil { return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    var window: AXUIElement? {
        guard let app else { return nil }
        if let w = AX.attr(app, kAXFocusedWindowAttribute) { return (w as! AXUIElement) }
        return (AX.attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    /// Waits until `match` finds something in the window, up to `timeout` seconds.
    func waitFor(_ timeout: Double = 6, _ match: @escaping (AXUIElement) -> Bool) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let w = window, let el = AX.find(in: w, match) { return el }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}

/// Developer tool: `open -n -a Time --args --ax <step> ...` runs steps against System Settings and
/// writes what it sees to ~/Library/Application Support/Time/ax-dump.txt, then quits.
/// Steps: url:<settings url>  press:<label>  wait:<seconds>  dump[:<depth>]  sheet
func runAXSteps(_ steps: [String]) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Time")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: [String] = []
    guard AX.trusted(prompt: true) else {
        out.append("NOT TRUSTED: grant Time Accessibility access in System Settings → Privacy & Security → Accessibility.")
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("ax-dump.txt"), atomically: true, encoding: .utf8)
        return
    }
    let ui = SettingsUI()
    ui.open()
    for step in steps {
        let (cmd, arg) = step.split(separator: ":", maxSplits: 1).map(String.init).splitPair()
        switch cmd {
        case "url":
            ui.open(URL(string: arg)!)
            Thread.sleep(forTimeInterval: 1.5)
            out.append("# opened \(arg)")
        case "press":
            if let el = ui.waitFor(6, { AX.label($0) == arg }) ?? ui.waitFor(2, { AX.label($0).localizedCaseInsensitiveContains(arg) }) {
                // Prefer the nearest pressable ancestor-or-self.
                let ok = AX.press(el) || AX.press(AX.attr(el, kAXParentAttribute) as! AXUIElement)
                out.append("# press \(arg): \(ok ? "ok" : "failed") (\(AX.role(el)))")
                Thread.sleep(forTimeInterval: 1.2)
            } else {
                out.append("# press \(arg): NOT FOUND")
            }
        case "id":
            if let el = ui.waitFor(6, { AX.str($0, kAXIdentifierAttribute as String) == arg }) {
                out.append("# press id \(arg): \(AX.press(el) ? "ok" : "failed")")
                Thread.sleep(forTimeInterval: 1.2)
            } else {
                out.append("# press id \(arg): NOT FOUND")
            }
        case "search":
            // Types into the search field of the open sheet (or the page, if no sheet).
            let scope: (AXUIElement) -> AXUIElement? = { w in AX.find(in: w, maxDepth: 3) { AX.role($0) == "AXSheet" } ?? w }
            if let w = ui.window, let field = AX.find(in: scope(w) ?? w, { AX.str($0, kAXSubroleAttribute) == "AXSearchField" }) {
                AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                let ok = AX.setValue(field, arg)
                AXUIElementPerformAction(field, "AXConfirm" as CFString)
                out.append("# search \(arg): \(ok ? "ok" : "failed")")
                Thread.sleep(forTimeInterval: 1.5)
            } else {
                out.append("# search: NO FIELD")
            }
        case "sheetdump":
            if let w = ui.window, let sheet = AX.find(in: w, maxDepth: 3, { AX.role($0) == "AXSheet" }) {
                out.append(AX.dump(sheet, maxDepth: Int(arg) ?? 40))
            } else { out.append("(no sheet)") }
        case "menu":
            // Opens a pop-up button (matched by value or identifier), lists its items, closes it again.
            if let w = ui.window, let pop = AX.find(in: w, { AX.role($0) == "AXPopUpButton" && (AX.str($0, kAXValueAttribute) == arg || AX.str($0, kAXIdentifierAttribute as String) == arg) }) {
                AX.press(pop)
                Thread.sleep(forTimeInterval: 0.8)
                let items = AX.findAll(in: pop, maxDepth: 4) { AX.role($0) == "AXMenuItem" }.map { AX.str($0, kAXTitleAttribute) }
                out.append("# menu \(arg): \(items)")
                if let menu = AX.find(in: pop, maxDepth: 2, { AX.role($0) == "AXMenu" }) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            } else { out.append("# menu \(arg): NOT FOUND") }
        case "pick":
            // Opens a pop-up button "<button>=<item>" and chooses the item.
            let parts = arg.components(separatedBy: "=")
            if parts.count == 2, let w = ui.window, let pop = AX.find(in: w, { AX.role($0) == "AXPopUpButton" && (AX.str($0, kAXValueAttribute) == parts[0] || AX.str($0, kAXIdentifierAttribute as String) == parts[0]) }) {
                AX.press(pop)
                Thread.sleep(forTimeInterval: 0.8)
                if let item = AX.find(in: pop, maxDepth: 4, { AX.role($0) == "AXMenuItem" && AX.str($0, kAXTitleAttribute) == parts[1] }) {
                    out.append("# pick \(arg): \(AX.press(item) ? "ok" : "failed")")
                } else {
                    out.append("# pick \(arg): ITEM NOT FOUND")
                    if let menu = AX.find(in: pop, maxDepth: 2, { AX.role($0) == "AXMenu" }) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
                }
                Thread.sleep(forTimeInterval: 1.5)
            } else { out.append("# pick \(arg): NOT FOUND") }
        case "wait":
            Thread.sleep(forTimeInterval: Double(arg) ?? 1)
        case "dump":
            out.append("# dump")
            if let w = ui.window { out.append(AX.dump(w, maxDepth: Int(arg) ?? 40)) } else { out.append("(no window)") }
        default:
            out.append("# unknown step \(step)")
        }
    }
    try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("ax-dump.txt"), atomically: true, encoding: .utf8)
}

extension Array where Element == String {
    func splitPair() -> (String, String) { (self.first ?? "", self.count > 1 ? self[1] : "") }
}
