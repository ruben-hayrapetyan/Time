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
    /// Work out of sight: open System Settings without taking focus and keep its window minimized.
    var background = false
    private(set) var wasRunning = false
    private var previous: NSRunningApplication?
    private var openedOnce = false
    private var originalPosition: CGPoint?

    func open(_ url: URL = screenTimeURL) {
        if !openedOnce {
            openedOnce = true
            wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).isEmpty
        }
        // System Settings only draws its pages while active, so it has to come forward briefly.
        if previous == nil { previous = NSWorkspace.shared.frontmostApplication }
        NSWorkspace.shared.open(url)
        for _ in 0..<200 {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first {
                app = AXUIElementCreateApplication(running.processIdentifier)
                if let w = window {
                    // Let the page draw its contents first; a window minimized before that stays blank.
                    if background, waitFor(8, { ["App & Website Activity", "App Limits", "Add Limit…"].contains(AX.label($0)) || AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTable" }) != nil {
                        Thread.sleep(forTimeInterval: 0.3)
                        // Slide the window off the bottom-right edge (minimizing would unload the page).
                        if originalPosition == nil, let v = AX.attr(w, kAXPositionAttribute) {
                            var p = CGPoint.zero
                            if AXValueGetValue(v as! AXValue, .cgPoint, &p) { originalPosition = p }
                        }
                        let frame = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
                        var pos = CGPoint(x: frame.maxX - 2, y: frame.maxY - 2)
                        if let v = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
                    }
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Puts things back: quits System Settings if we were the ones who opened it.
    func finish() {
        guard background, let running = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first else { return }
        if !wasRunning {
            running.terminate()
        } else if let w = window, var p = originalPosition, let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
        }
        // Settings has to stay the active app while it's being read; hand focus back now.
        if let previous, previous.bundleIdentifier != settingsBundleID { previous.activate() }
    }

    var window: AXUIElement? {
        guard let app else { return nil }
        // A minimized window is never the focused one, so look through all of them.
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
    ui.background = steps.first == "bg"
    ui.open()
    for step in steps where step != "bg" {
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
        case "expand":
            // Opens the disclosure triangle on the outline row labelled `arg` ("*" = every row).
            if let w = ui.window {
                let rows = AX.findAll(in: w) { AX.role($0) == "AXRow" && AX.children($0).contains { c in AX.children(c).contains { arg == "*" || AX.label($0) == arg } } }
                var n = 0
                for row in rows {
                    if let tri = AX.find(in: row, maxDepth: 3, { AX.role($0) == "AXDisclosureTriangle" }), AX.str(tri, kAXValueAttribute) == "0" {
                        AX.press(tri); n += 1
                        Thread.sleep(forTimeInterval: 0.4)
                    }
                }
                out.append("# expand \(arg): \(n) opened")
            }
        case "minimize":
            if let w = ui.window {
                let ok = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
                out.append("# minimize: \(ok ? "ok" : "failed")")
                Thread.sleep(forTimeInterval: 1)
            }
        case "alldump":
            for w in (ui.app.flatMap { AX.attr($0, kAXWindowsAttribute) as? [AXUIElement] } ?? []) {
                out.append("## window \(AX.str(w, kAXTitleAttribute)) minimized=\(AX.str(w, kAXMinimizedAttribute)) focused=\(AX.str(w, kAXFocusedAttribute))")
                out.append(AX.dump(w, maxDepth: Int(arg) ?? 40))
            }
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
