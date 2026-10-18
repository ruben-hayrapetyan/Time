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

    static func settable(_ el: AXUIElement, _ name: String = kAXValueAttribute) -> Bool {
        var ok = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, name as CFString, &ok) == .success && ok.boolValue
    }

    static func setValue(_ el: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString) == .success
    }

    /// The element's middle, in screen coordinates (top-left origin, like CGEvent).
    static func center(_ el: AXUIElement) -> CGPoint? {
        guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    /// The process with keyboard focus, asked of Accessibility directly (NSWorkspace's
    /// frontmostApplication only updates while a run loop is turning).
    static func focusedPID() -> pid_t? {
        guard let app = attr(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app as! AXUIElement, &pid) == .success ? pid : nil
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

/// The real mouse pointer. A few Screen Time controls only answer to it: the minutes field
/// takes a click, and a limit's Edit… button only exists while the pointer is over its row.
enum Pointer {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func hover(_ pt: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.6)
    }

    static func click(_ pt: CGPoint) {
        hover(pt)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    static func warp(_ pt: CGPoint) { CGWarpMouseCursorPosition(pt) }
}

/// Key presses, for the Screen Time passcode boxes (they ignore values set through Accessibility).
/// They go to whichever app is in front, so callers check that first.
enum Keyboard {
    static let digitCodes: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]

    static func type(_ digits: String) {
        for d in digits {
            guard let code = digitCodes[d] else { continue }
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
            }
            Thread.sleep(forTimeInterval: 0.35)
        }
    }
}

/// The System Settings app as an accessibility element, launching it if needed.
final class SettingsUI {
    var app: AXUIElement?
    /// Work out of sight: open System Settings without taking focus and keep its window minimized.
    var background = false
    private(set) var wasRunning = false
    private var previous: NSRunningApplication?
    var previousApp: NSRunningApplication? { previous }
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

    /// Runs `body` with the window back where the user had it (pointer events need it on screen),
    /// then slides it away again and puts the pointer back where it was.
    func onScreen<T>(_ body: () throws -> T) rethrows -> T {
        let pointer = Pointer.location
        let hidden = background ? window.flatMap { AX.attr($0, kAXPositionAttribute) } : nil
        if hidden != nil, let w = window, var p = visiblePosition(), let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
        }
        bringToFront()
        defer {
            Pointer.warp(pointer)
            if let hidden, let w = window { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, hidden) }
        }
        return try body()
    }

    /// Where the window was before Time moved it, or the middle of the main screen if that
    /// spot isn't on any screen (System Settings was already parked off-screen, say after a crash).
    func visiblePosition() -> CGPoint? {
        guard let main = NSScreen.screens.first else { return originalPosition }
        // Accessibility positions are top-left based, measured from the top of the main screen.
        let size: CGSize = window.flatMap { AX.attr($0, kAXSizeAttribute) }.map { v in
            var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s
        } ?? CGSize(width: 700, height: 600)
        if let p = originalPosition {
            let corner = NSPoint(x: p.x + 60, y: main.frame.maxY - p.y - 60)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(corner) }) { return p }
        }
        let vf = main.visibleFrame
        return CGPoint(x: vf.midX - size.width / 2, y: max(main.frame.maxY - vf.maxY, main.frame.maxY - vf.midY - size.height / 2))
    }

    /// Brings System Settings to the front, on its current page, the way clicking its Dock icon does.
    /// (A plain activate() from a background app is ignored on recent macOS.)
    var isFrontmost: Bool {
        AX.focusedPID() == NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first?.processIdentifier
    }

    func bringToFront() {
        guard !isFrontmost, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settingsBundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<50 where !isFrontmost {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Puts things back: quits System Settings if we were the ones who opened it.
    func finish() {
        guard background, let running = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first else { return }
        if !wasRunning {
            running.terminate()
            // Wait for it to be gone, so the next job doesn't latch onto a window that's closing.
            for _ in 0..<50 where !running.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
        } else if let w = window, var p = visiblePosition(), let v = AXValueCreate(.cgPoint, &p) {
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

#if TIME_DEVTOOLS
/// Developer tool, in `./build-app.sh --dev` builds only: `open -n -a Time --args --ax <step> ...` runs
/// steps against System Settings and writes what it sees to ~/Library/Application Support/Time/ax-dump.txt,
/// then quits.
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
        case "toggle":
            // Presses the switch that shares a group with the text `arg`.
            if let w = ui.window,
               let group = AX.find(in: w, { el in AX.children(el).contains { AX.label($0) == arg } && AX.children(el).contains { AX.role($0) == "AXCheckBox" } }),
               let sw = AX.children(group).first(where: { AX.role($0) == "AXCheckBox" }) {
                out.append("# toggle \(arg) (was \(AX.str(sw, kAXValueAttribute as String))): \(AX.press(sw) ? "ok" : "failed")")
                Thread.sleep(forTimeInterval: 1.5)
            } else {
                out.append("# toggle \(arg): NOT FOUND")
            }
        case "check":
            // Presses the checkbox on the Add Limit row named `arg`.
            if let w = ui.window, let cb = AX.find(in: w, { el in AX.role(el) == "AXCheckBox" && AX.children(AX.attr(el, kAXParentAttribute) as! AXUIElement).contains { AX.label($0) == arg } }) {
                out.append("# check \(arg): \(AX.press(cb) ? "ok" : "failed")")
                Thread.sleep(forTimeInterval: 0.8)
            } else { out.append("# check \(arg): NOT FOUND") }
        case "incr":
            if let w = ui.window, let inc = AX.find(in: w, { AX.role($0) == "AXIncrementor" }) {
                for _ in 0..<(Int(arg) ?? 1) { AXUIElementPerformAction(inc, kAXIncrementAction as CFString); Thread.sleep(forTimeInterval: 0.3) }
                out.append("# incr: now \(AX.str(inc, kAXValueAttribute))")
            } else { out.append("# incr: NOT FOUND") }
        case "hover", "click":
            // Moves the real pointer onto the element labelled `arg` ("<label>#<n>" for the n-th match); "click" also clicks.
            let parts = arg.components(separatedBy: "#")
            let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let matches = ui.window.map { w in AX.findAll(in: w, { AX.label($0) == parts[0] }) } ?? []
            if n < matches.count, let pt = AX.center(matches[n]) {
                cmd == "click" ? Pointer.click(pt) : Pointer.hover(pt)
                out.append("# \(cmd) \(arg) at \(pt)")
            } else { out.append("# \(cmd) \(arg): NOT FOUND (\(matches.count) matches)") }
        case "type":
            // Types digits into the open sheet: "type:ax:<digits>" sets the field's value, "type:key:<digits>" sends key presses.
            let parts = arg.components(separatedBy: ":")
            if parts.count == 2, let sheet = ui.window.flatMap({ w in AX.find(in: w, maxDepth: 3) { AX.role($0) == "AXSheet" } }),
               let field = AX.find(in: sheet, { AX.role($0) == "AXTextField" }) {
                AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                let boxes = { AX.findAll(in: sheet) { AX.str($0, kAXSubroleAttribute) == "AXPasscodeBox" }.map { "\(AX.role($0).dropFirst(2))@\(AX.center($0).map { Int($0.x) } ?? -1)" }.joined(separator: " ") }
                let before = boxes()
                if parts[0] == "ax" { out.append("# type ax: \(AX.setValue(field, parts[1]) ? "ok" : "failed")") } else { Keyboard.type(parts[1]); out.append("# type key") }
                Thread.sleep(forTimeInterval: 1)
                out.append("#   boxes \(before) -> \(boxes())")
            } else { out.append("# type: NO FIELD") }
        case "show":
            // Puts the window back on screen without bringing System Settings forward.
            if let w = ui.window, var p = ui.visiblePosition(), let v = AXValueCreate(.cgPoint, &p) {
                AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
                Thread.sleep(forTimeInterval: 0.5)
                out.append("# show at \(p)")
            }
        case "front":
            ui.bringToFront()
            out.append("# front: settings focused=\(ui.isFrontmost)")
        case "back":
            // Hands focus back to the app that was in front before System Settings opened.
            if let prev = ui.previousApp, let url = prev.bundleURL {
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                Thread.sleep(forTimeInterval: 0.8)
                out.append("# back to \(prev.localizedName ?? "?")")
            }
        case "where":
            // Window frame and the centers of elements labelled `arg`, to see what's inside the visible area.
            if let w = ui.window {
                let wp = AX.attr(w, kAXPositionAttribute).map { v -> CGPoint in var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p } ?? .zero
                let ws = AX.attr(w, kAXSizeAttribute).map { v -> CGSize in var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s } ?? .zero
                out.append("# window \(wp) \(ws)")
                for el in AX.findAll(in: w, { AX.label($0) == arg }) { out.append("#   \(arg) at \(AX.center(el).map { "\($0)" } ?? "?")") }
            }
        case "attrs":
            // Attribute names (settable marked *) of elements whose label or id is `arg`, and of their parents.
            if let w = ui.window {
                func names(_ el: AXUIElement) -> String {
                    var n: CFArray?
                    AXUIElementCopyAttributeNames(el, &n)
                    return ((n as? [String]) ?? []).map { "\($0)\(AX.settable(el, $0) ? "*" : "")=\(AX.str(el, $0).prefix(30))" }.joined(separator: " ")
                }
                for el in AX.findAll(in: w, { AX.label($0) == arg || AX.str($0, kAXIdentifierAttribute as String) == arg }).prefix(4) {
                    out.append("# \(AX.role(el)): \(names(el))")
                    if let p = AX.attr(el, kAXParentAttribute) { out.append("    parent \(AX.role(p as! AXUIElement)): \(names(p as! AXUIElement))") }
                }
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
    // Put the window back (or quit System Settings) so a later run doesn't start from off-screen.
    ui.finish()
}

extension Array where Element == String {
    func splitPair() -> (String, String) { (self.first ?? "", self.count > 1 ? self[1] : "") }
}
#endif
