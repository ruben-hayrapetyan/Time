// Reads your Screen Time "App & Website Activity" list (all devices, this week) out of
// System Settings, so Time's toggles match the apps you actually use.
import AppKit
import ApplicationServices

struct ScreenTimeItem: Codable {
    var name: String
    var seconds: Int
    var hasLimit: Bool
    var category: String? = nil
    var source: String = "activity"   // "activity" (has usage) or "limits" (only in the Add Limit list)
}

enum ScreenTimeError: LocalizedError {
    case notTrusted, notFound(String), otherPasscode, lostFocus, wrongPasscode
    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Time needs Accessibility access: System Settings → Privacy & Security → Accessibility → Time."
        case .notFound(let what): return "Couldn't find \(what) in Screen Time settings."
        case .otherPasscode: return "Screen Time already has a passcode that Time didn't set, so Time can't change limits. Turn it off in System Settings → Screen Time first."
        case .lostFocus: return "Another app came to the front while Time was entering the Screen Time passcode. It will try again shortly."
        case .wrongPasscode: return "Screen Time didn't accept the passcode Time saved."
        }
    }
}

extension SettingsUI {
    /// Navigates to Screen Time's top page, whatever subpage System Settings was left on.
    func goToScreenTimeHome() throws {
        open()
        for _ in 0..<8 {
            if waitFor(1.5, { AX.role($0) == "AXButton" && AX.label($0) == "App & Website Activity" }) != nil { return }
            if let back = waitFor(1, { AX.str($0, kAXIdentifierAttribute as String) == "go back" }) { AX.press(back) }
            Thread.sleep(forTimeInterval: 0.8)
        }
        throw ScreenTimeError.notFound("the Screen Time page")
    }

    var sheet: AXUIElement? { window.flatMap { w in AX.find(in: w, maxDepth: 3) { AX.role($0) == "AXSheet" } } }
}

final class ScreenTimeReader {
    let ui: SettingsUI = { let u = SettingsUI(); u.background = true; return u }()

    private func popup(where match: @escaping ([String]) -> Bool) -> AXUIElement? {
        guard let w = ui.window else { return nil }
        for pop in AX.findAll(in: w, { AX.role($0) == "AXPopUpButton" }) {
            AX.press(pop)
            Thread.sleep(forTimeInterval: 0.5)
            let items = AX.findAll(in: pop, maxDepth: 4) { AX.role($0) == "AXMenuItem" }.map { AX.str($0, kAXTitleAttribute) }
            if let menu = AX.find(in: pop, maxDepth: 2, { AX.role($0) == "AXMenu" }) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            Thread.sleep(forTimeInterval: 0.3)
            if match(items) { return pop }
        }
        return nil
    }

    private func choose(_ pop: AXUIElement, _ title: String) {
        if AX.str(pop, kAXValueAttribute) == title { return }
        AX.press(pop)
        Thread.sleep(forTimeInterval: 0.5)
        if let item = AX.find(in: pop, maxDepth: 4, { AX.role($0) == "AXMenuItem" && AX.str($0, kAXTitleAttribute) == title }) {
            AX.press(item)
        } else if let menu = AX.find(in: pop, maxDepth: 2, { AX.role($0) == "AXMenu" }) {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    func readActivity() throws -> [ScreenTimeItem] {
        guard AX.trusted(prompt: true) else { throw ScreenTimeError.notTrusted }
        try ui.goToScreenTimeHome()
        guard let open = ui.waitFor(3, { AX.role($0) == "AXButton" && AX.label($0) == "App & Website Activity" }) else {
            throw ScreenTimeError.notFound("App & Website Activity")
        }
        AX.press(open)
        guard ui.waitFor(6, { AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTable" }) != nil else {
            throw ScreenTimeError.notFound("the app list")
        }
        if let device = popup(where: { $0.contains("All Devices") }) { choose(device, "All Devices") }
        if let range = popup(where: { $0.contains("This Week") }) { choose(range, "This Week") }
        if let kind = ui.waitFor(2, { AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTablePicker" }) { choose(kind, "Show Apps") }

        guard let w = ui.window, let table = AX.find(in: w, { AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTable" }) else {
            throw ScreenTimeError.notFound("the app list")
        }
        var items: [ScreenTimeItem] = []
        for row in AX.children(table) where AX.role(row) == "AXRow" {
            let name = AX.find(in: row, { AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTableNameText" }).map { AX.str($0, kAXValueAttribute) } ?? ""
            let time = AX.find(in: row, { AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTableTimeText" }).map { AX.str($0, kAXValueAttribute) } ?? ""
            let limited = AX.find(in: row, { AX.str($0, kAXIdentifierAttribute as String) == "mostUsedTableLimitIcon" }) != nil
            if name.isEmpty || name == "All Usage" { continue }
            items.append(ScreenTimeItem(name: name, seconds: parseDuration(time), hasLimit: limited))
        }
        if items.isEmpty { throw ScreenTimeError.notFound("any apps") }
        return items
    }

    /// Reads Screen Time's categories (Social, Games, …) and the apps in each from the
    /// "Add Limit…" form, then cancels the form without saving anything.
    func readCategories() throws -> [(category: String, apps: [String])] {
        try ui.goToScreenTimeHome()
        guard let limits = ui.waitFor(3, { AX.role($0) == "AXButton" && AX.label($0) == "App Limits" }) else {
            throw ScreenTimeError.notFound("App Limits")
        }
        AX.press(limits)
        guard let add = ui.waitFor(6, { AX.role($0) == "AXButton" && AX.label($0) == "Add Limit…" }) else {
            throw ScreenTimeError.notFound("Add Limit…")
        }
        AX.press(add)
        guard let outline = ui.waitFor(6, { AX.role($0) == "AXOutline" && AX.str($0, kAXDescriptionAttribute) == "Apps outline view" }) else {
            throw ScreenTimeError.notFound("the app categories")
        }
        defer {
            // Always leave through Cancel so nothing is ever saved.
            if let w = ui.window, let sheet = AX.find(in: w, maxDepth: 3, { AX.role($0) == "AXSheet" }),
               let cancel = AX.find(in: sheet, { AX.role($0) == "AXButton" && AX.label($0) == "Cancel" }) {
                AX.press(cancel)
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        // Expand every category; expanding inserts rows, so re-read the rows after each one.
        var opened = Set<String>()
        while true {
            let rows = AX.children(outline).filter { AX.role($0) == "AXRow" }
            guard let next = rows.first(where: { row in
                guard let tri = AX.find(in: row, maxDepth: 3, { AX.role($0) == "AXDisclosureTriangle" }) else { return false }
                return AX.str(tri, kAXValueAttribute) == "0" && !opened.contains(rowName(row))
            }) else { break }
            opened.insert(rowName(next))
            if let tri = AX.find(in: next, maxDepth: 3, { AX.role($0) == "AXDisclosureTriangle" }) { AX.press(tri) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        var out: [(category: String, apps: [String])] = []
        for row in AX.children(outline) where AX.role(row) == "AXRow" {
            let name = rowName(row)
            if name.isEmpty || name == "All Apps & Categories" { continue }
            let isCategory = AX.find(in: row, maxDepth: 3, { AX.role($0) == "AXDisclosureTriangle" }) != nil
            if isCategory { out.append((name, [])) } else if !out.isEmpty { out[out.count - 1].apps.append(name) }
        }
        if out.isEmpty { throw ScreenTimeError.notFound("any categories") }
        return out
    }

    private func rowName(_ row: AXUIElement) -> String {
        guard let cell = AX.children(row).first,
              let text = AX.children(cell).first(where: { AX.role($0) == "AXStaticText" }) else { return "" }
        return AX.str(text, kAXValueAttribute)
    }

    /// Activity (with usage) plus categories, merged into one list.
    func readAll() throws -> [ScreenTimeItem] {
        defer { ui.finish() }
        var items = try readActivity()
        let cats = (try? readCategories()) ?? []
        var categoryOf: [String: String] = [:]
        for c in cats { for a in c.apps { categoryOf[a] = c.category } }
        // Activity names and Add Limit names usually match; when they don't (iPhone apps sometimes
        // show up as bundle IDs there), match on the app's short name.
        let sheetNames = Array(categoryOf.keys)
        var matched = Set<String>()
        for i in items.indices {
            let name = items[i].name, k = matchKey(name)
            let hit = categoryOf[name] != nil ? name
                : sheetNames.first(where: { matchKey($0) == k })
                ?? sheetNames.first(where: { let o = matchKey($0); return o.count >= 4 && k.count >= 4 && (o.hasPrefix(k) || k.hasPrefix(o)) })
            if let hit {
                items[i].category = categoryOf[hit]
                matched.insert(hit)
            }
        }
        for c in cats where c.category != "Websites" {
            for a in c.apps where !matched.contains(a) {
                matched.insert(a)
                items.append(ScreenTimeItem(name: a, seconds: 0, hasLimit: false, category: c.category, source: "limits"))
            }
        }
        return items
    }
}

/// Adds and removes Time's own App Limits: one per locked app, 1 minute a day. With "Share
/// across devices" on, Screen Time applies them on the iPhone and iPad too, which is how a lock
/// reaches the phone. Time only ever removes limits it added (it remembers their titles), and
/// only ones that still read exactly "1min, Every Day".
final class ScreenTimeWriter {
    static let detail = "1min, Every Day"
    let ui: SettingsUI = { let u = SettingsUI(); u.background = true; return u }()

    struct LimitRow { var title: String; var detail: String; var detailElement: AXUIElement }

    private func goToAppLimits() throws {
        guard AX.trusted(prompt: false) else { throw ScreenTimeError.notTrusted }
        try ui.goToScreenTimeHome()
        guard let limits = ui.waitFor(3, { AX.role($0) == "AXButton" && AX.label($0) == "App Limits" }) else {
            throw ScreenTimeError.notFound("App Limits")
        }
        AX.press(limits)
        guard ui.waitFor(6, { AX.role($0) == "AXButton" && AX.label($0) == "Add Limit…" }) != nil else {
            throw ScreenTimeError.notFound("Add Limit…")
        }
        if let main = ui.waitFor(2, { AX.role($0) == "AXCheckBox" && AX.str($0, kAXSubroleAttribute) == "AXSwitch" }), AX.str(main, kAXValueAttribute) == "0" {
            throw ScreenTimeError.notFound("App Limits turned on (switch it on in Screen Time → App Limits)")
        }
    }

    /// The limits on the App Limits page. Right after System Settings opens, titles show bundle IDs
    /// ("com.burbn.instagram") for a moment before the app names arrive, so wait for those to settle.
    private func rows() -> [LimitRow] {
        let looksLikeID = try! NSRegularExpression(pattern: #"(^|, |& )[a-z0-9-]+\.[a-z0-9-]+\.[A-Za-z0-9.-]+"#)
        var last = readRows()
        for _ in 0..<6 {
            let unresolved = last.contains { looksLikeID.firstMatch(in: $0.title, range: NSRange($0.title.startIndex..., in: $0.title)) != nil }
            if !unresolved && !last.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
            last = readRows()
        }
        return last
    }

    /// Each row is title, detail, [Edit… while hovered], on/off toggle.
    private func readRows() -> [LimitRow] {
        guard let add = ui.waitFor(3, { AX.role($0) == "AXButton" && AX.label($0) == "Add Limit…" }),
              let group = AX.attr(add, kAXParentAttribute) else { return [] }
        var out: [LimitRow] = [], texts: [AXUIElement] = []
        for el in AX.children(group as! AXUIElement) {
            if AX.role(el) == "AXStaticText" { texts.append(el) }
            if AX.role(el) == "AXCheckBox" {
                if texts.count >= 2 { out.append(LimitRow(title: AX.label(texts[texts.count - 2]), detail: AX.label(texts[texts.count - 1]), detailElement: texts[texts.count - 1])) }
                texts = []
            }
        }
        return out
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = AX.attr(el, kAXPositionAttribute), let sv = AX.attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// The scrolling list an element sits in.
    private func scrollArea(of el: AXUIElement) -> AXUIElement? {
        var node = el
        for _ in 0..<12 {
            guard let parent = AX.attr(node, kAXParentAttribute) else { return nil }
            node = parent as! AXUIElement
            if AX.role(node) == "AXScrollArea" { return node }
        }
        return nil
    }

    /// Whether the element's middle is inside its list's visible area.
    private func isVisible(_ el: AXUIElement) -> Bool {
        guard let pt = AX.center(el), let area = scrollArea(of: el).flatMap(frame) else { return false }
        return area.insetBy(dx: 0, dy: 20).contains(pt)
    }

    /// Pages the list until the element is in view (a long list of limits runs past the window's bottom).
    private func scrollIntoView(_ el: AXUIElement) {
        guard let area = scrollArea(of: el) else { return }
        for _ in 0..<10 where !isVisible(el) {
            guard let pt = AX.center(el), let box = frame(area) else { return }
            AXUIElementPerformAction(area, (pt.y > box.midY ? "AXScrollDownByPage" : "AXScrollUpByPage") as CFString)
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Whether a row is one of Time's limits for `title` (matching an unresolved bundle-ID title too).
    private func isOurs(_ row: LimitRow, _ title: String) -> Bool {
        row.detail == Self.detail && (row.title == title || matchKey(row.title) == matchKey(title))
    }

    private func count(_ title: String, in rows: [LimitRow]) -> Int { rows.filter { isOurs($0, title) }.count }

    private func cancelSheets() {
        for _ in 0..<2 {
            guard let sheet = ui.sheet, let cancel = AX.find(in: sheet, { AX.role($0) == "AXButton" && AX.label($0) == "Cancel" }) else { return }
            AX.press(cancel)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    /// With a Screen Time passcode on, every change asks for it first. Changes only happen while
    /// Time's own passcode is off, so a prompt here means someone else's passcode.
    private func checkNoPasscodePrompt() throws {
        if ui.waitFor(1.5, { AX.role($0) == "AXStaticText" && AX.label($0) == "Enter Screen Time Passcode" }) != nil {
            throw ScreenTimeError.otherPasscode
        }
    }

    // MARK: passcode

    private func passcodeSwitch() -> AXUIElement? {
        guard let label = ui.waitFor(3, { AX.role($0) == "AXStaticText" && AX.label($0) == "Lock Screen Time Settings" }),
              let group = AX.attr(label, kAXParentAttribute) else { return nil }
        return AX.children(group as! AXUIElement).first { AX.role($0) == "AXCheckBox" }
    }

    /// Turns on "Lock Screen Time Settings" with `code`. With "Share across devices" on, the
    /// passcode guards the iPhone's limits too, so "Ignore Limit" there asks for it.
    /// When `retrying`, a passcode that's already on is the one an earlier, interrupted attempt set.
    func setPasscode(_ code: String, retrying: Bool = false) throws {
        guard AX.trusted(prompt: false) else { throw ScreenTimeError.notTrusted }
        try ui.goToScreenTimeHome()
        guard let sw = passcodeSwitch() else { throw ScreenTimeError.notFound("Lock Screen Time Settings") }
        if AX.str(sw, kAXValueAttribute) == "1" {
            if retrying { return }
            throw ScreenTimeError.otherPasscode
        }
        AX.press(sw)
        defer { cancelSheets() }
        // Admin accounts are first offered a switch to a standard account; Time keeps you an admin.
        if let keepAdmin = ui.waitFor(3, { AX.role($0) == "AXRadioButton" && AX.label($0) == "Allow this user to administer this computer" }) {
            AX.press(keepAdmin)
            if let next = ui.waitFor(2, { AX.role($0) == "AXButton" && AX.label($0) == "Continue" }) { AX.press(next) }
        }
        try enterCode(code, at: "Set a Screen Time Passcode")
        try enterCode(code, at: "Re-enter Screen Time Passcode")
        Thread.sleep(forTimeInterval: 1.5)
        guard ui.sheet == nil, passcodeSwitch().map({ AX.str($0, kAXValueAttribute) }) == "1" else {
            throw ScreenTimeError.notFound("the passcode switched on after entering it")
        }
    }

    /// Turns "Lock Screen Time Settings" off again. Already off counts as done.
    func removePasscode(_ code: String) throws {
        guard AX.trusted(prompt: false) else { throw ScreenTimeError.notTrusted }
        try ui.goToScreenTimeHome()
        guard let sw = passcodeSwitch() else { throw ScreenTimeError.notFound("Lock Screen Time Settings") }
        if AX.str(sw, kAXValueAttribute) == "0" { return }
        AX.press(sw)
        defer { cancelSheets() }
        try enterCode(code, at: "Enter Screen Time Passcode")
        Thread.sleep(forTimeInterval: 1.5)
        guard passcodeSwitch().map({ AX.str($0, kAXValueAttribute) }) == "0" else { throw ScreenTimeError.wrongPasscode }
    }

    /// Types the code into the passcode boxes under `heading`. They ignore values set through
    /// Accessibility and only take key presses, which go to the front app, so the window comes
    /// on screen and nothing is typed unless System Settings is in front. Any other sheet (an
    /// account or password prompt) is left alone and cancelled.
    private func enterCode(_ code: String, at heading: String) throws {
        guard ui.waitFor(4, { AX.role($0) == "AXStaticText" && AX.label($0) == heading }) != nil, let sheet = ui.sheet,
              let field = AX.find(in: sheet, { AX.role($0) == "AXTextField" && AX.str($0, kAXSubroleAttribute) == "AXPasscodeBox" }) else {
            throw ScreenTimeError.notFound("“\(heading)”")
        }
        try ui.onScreen {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard ui.isFrontmost else { throw ScreenTimeError.lostFocus }
            Keyboard.type(code)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Hours and minutes currently shown in the sheet's time picker.
    private func pickerTime(_ sheet: AXUIElement) -> [String] {
        guard let picker = AX.find(in: sheet, { AX.str($0, kAXDescriptionAttribute) == "Time Amount Picker" }) else { return [] }
        return AX.findAll(in: picker, maxDepth: 2) { AX.role($0) == "AXButton" }.map { AX.str($0, kAXTitleAttribute) }
    }

    /// Adds a 1-minute, every-day limit for the app Screen Time calls `name`. Returns the new limit's title.
    /// With `passcode` (Time's own, already on), the limit is set to "Block at end of limit", which
    /// takes "Ignore Limit" away on every device; Screen Time only offers that while a passcode is on.
    func addLimit(_ name: String, passcode: String? = nil) throws -> String {
        try goToAppLimits()
        let before = rows()
        guard let add = ui.waitFor(3, { AX.role($0) == "AXButton" && AX.label($0) == "Add Limit…" }) else { throw ScreenTimeError.notFound("Add Limit…") }
        AX.press(add)
        defer { cancelSheets() }
        if ui.waitFor(1.5, { AX.role($0) == "AXStaticText" && AX.label($0) == "Enter Screen Time Passcode" }) != nil {
            guard let passcode else { throw ScreenTimeError.otherPasscode }
            try enterCode(passcode, at: "Enter Screen Time Passcode")
        }
        guard let outline = ui.waitFor(6, { AX.role($0) == "AXOutline" && AX.str($0, kAXDescriptionAttribute) == "Apps outline view" }),
              let sheet = ui.sheet else { throw ScreenTimeError.notFound("the Add Limit form") }

        if let field = AX.find(in: sheet, { AX.str($0, kAXSubroleAttribute) == "AXSearchField" }) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AX.setValue(field, name)
            AXUIElementPerformAction(field, "AXConfirm" as CFString)
        }
        // Search results are flat rows: name, checkbox, icon, "— Category". They can take a few seconds to fill in.
        var match: (String, AXUIElement)?
        for _ in 0..<12 where match == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let found = AX.children(outline).filter { AX.role($0) == "AXRow" }.compactMap { row -> (String, AXUIElement)? in
                guard let cell = AX.children(row).first,
                      let text = AX.children(cell).first(where: { AX.role($0) == "AXStaticText" }),
                      let box = AX.children(cell).first(where: { AX.role($0) == "AXCheckBox" }) else { return nil }
                return (AX.str(text, kAXValueAttribute), box)
            }
            match = found.first(where: { $0.0 == name }) ?? found.first(where: { matchKey($0.0) == matchKey(name) })
        }
        guard let (title, box) = match else { throw ScreenTimeError.notFound("\(name) in the Add Limit list") }
        for _ in 0..<3 where AX.str(box, kAXValueAttribute) != "1" {
            AX.press(box)
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard AX.str(box, kAXValueAttribute) == "1" else { throw ScreenTimeError.notFound("a way to tick \(title) in the Add Limit list") }
        if let everyDay = AX.find(in: sheet, { AX.role($0) == "AXRadioButton" && AX.str($0, kAXTitleAttribute) == "Every Day" }),
           AX.str(everyDay, kAXValueAttribute) != "1" { AX.press(everyDay) }

        // The stepper changes whichever field was clicked last (hours by default), and only a real click selects one.
        guard let picker = AX.find(in: sheet, { AX.str($0, kAXDescriptionAttribute) == "Time Amount Picker" }),
              let stepper = AX.find(in: picker, { AX.role($0) == "AXIncrementor" }) else { throw ScreenTimeError.notFound("the time picker") }
        let fields = AX.findAll(in: picker, maxDepth: 2) { AX.role($0) == "AXButton" }
        guard fields.count == 2 else { throw ScreenTimeError.notFound("the minutes field") }
        ui.onScreen {
            if let pt = AX.center(fields[1]) { Pointer.click(pt) }
        }
        AXUIElementPerformAction(stepper, kAXIncrementAction as CFString)
        Thread.sleep(forTimeInterval: 0.4)
        guard pickerTime(sheet) == ["0", "1"] else { throw ScreenTimeError.notFound("a way to set the limit to 1 minute (got \(pickerTime(sheet).joined(separator: ":")))") }
        if passcode != nil {
            guard let block = AX.find(in: sheet, { AX.role($0) == "AXCheckBox" && AX.str($0, kAXTitleAttribute) == "Block at end of limit" }) else {
                throw ScreenTimeError.notFound("“Block at end of limit”")
            }
            if AX.str(block, kAXValueAttribute) != "1" { AX.press(block) }
            Thread.sleep(forTimeInterval: 0.3)
            guard AX.str(block, kAXValueAttribute) == "1" else { throw ScreenTimeError.notFound("a way to tick “Block at end of limit”") }
        }

        guard let done = AX.find(in: sheet, { AX.role($0) == "AXButton" && AX.label($0) == "Done" }) else { throw ScreenTimeError.notFound("Done") }
        AX.press(done)
        // Once the form closes the limit is saved, even if the list behind it is slow to show it.
        // Reporting a failure here would make Time add a duplicate on the next try.
        for _ in 0..<10 where ui.sheet != nil { Thread.sleep(forTimeInterval: 0.3) }
        guard ui.sheet == nil else { throw ScreenTimeError.notFound("the Add Limit form closing after Done") }
        for _ in 0..<4 where count(title, in: rows()) <= count(title, in: before) { Thread.sleep(forTimeInterval: 0.5) }
        return title
    }

    /// Removes every 1-minute limit titled `title` (leftovers from interrupted runs included).
    /// Returns how many it removed.
    @discardableResult
    func removeLimits(_ title: String) throws -> Int {
        var n = 0
        while n < 20, try removeLimit(title) { n += 1 }
        return n
    }

    /// Removes one of the 1-minute limits titled `title`. Returns false if there was none left.
    @discardableResult
    func removeLimit(_ title: String) throws -> Bool {
        try goToAppLimits()
        let all = rows()
        // No rows at all means the page didn't load properly, not that the limit is gone.
        if all.isEmpty { throw ScreenTimeError.notFound("the list of App Limits") }
        let ours = all.filter { $0.title == title && $0.detail == Self.detail }
        let candidates = ours.isEmpty ? all.filter { isOurs($0, title) } : ours
        guard !candidates.isEmpty else { return false }
        let before = count(title, in: all)
        // A limit's Edit… button only appears while the pointer is over its row, right after that
        // row's detail text. Any of our rows will do, so prefer one that's already in view; moving
        // the window on screen can shift the layout, so re-aim until the button shows up on our
        // row and not a neighbour's.
        try ui.onScreen {
            for _ in 0..<3 {
                let row = candidates.first(where: { isVisible($0.detailElement) }) ?? candidates[0]
                scrollIntoView(row.detailElement)
                guard let pt = AX.center(row.detailElement) else { break }
                Pointer.hover(pt)
                let items = AX.attr(row.detailElement, kAXParentAttribute).map { AX.children($0 as! AXUIElement) } ?? []
                for i in items.indices.dropLast(2) where AX.label(items[i]) == row.title && AX.label(items[i + 1]) == row.detail
                    && AX.role(items[i + 2]) == "AXButton" && AX.str(items[i + 2], kAXDescriptionAttribute) == "Edit…" {
                    AX.press(items[i + 2])
                    return
                }
            }
            throw ScreenTimeError.notFound("Edit… on the limit for \(title)")
        }
        defer { cancelSheets() }
        try checkNoPasscodePrompt()
        guard ui.waitFor(4, { AX.role($0) == "AXButton" && AX.label($0) == "Remove Limit…" }) != nil, let sheet = ui.sheet else {
            throw ScreenTimeError.notFound("Remove Limit…")
        }
        // Make sure this is the limit Time made before removing it.
        let heading = AX.find(in: sheet, { AX.role($0) == "AXStaticText" && AX.label($0).hasPrefix("Edit app limit for") }).map(AX.label) ?? ""
        guard heading.contains(title), pickerTime(sheet) == ["0", "1"] else {
            throw ScreenTimeError.notFound("the 1-minute limit for \(title) (opened \"\(heading)\")")
        }
        if let remove = AX.find(in: sheet, { AX.role($0) == "AXButton" && AX.label($0) == "Remove Limit…" }) { AX.press(remove) }
        guard let confirm = ui.waitFor(3, { AX.str($0, kAXIdentifierAttribute as String) == "action-button-1" && AX.label($0) == "Remove Limit" }) else {
            throw ScreenTimeError.notFound("the Remove Limit confirmation")
        }
        AX.press(confirm)
        Thread.sleep(forTimeInterval: 1.5)
        guard count(title, in: rows()) < before else { throw ScreenTimeError.notFound("the limit for \(title) gone after removing it") }
        return true
    }
}

/// "Discord - Talk, Play, Hang Out" → "discord"; "com.flowerave.sidechat" → "sidechat".
func matchKey(_ name: String) -> String {
    var n = name
    if n.range(of: #"^[a-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil {
        let generic: Set<String> = ["app", "ios", "iphone", "iphone-app", "mobile", "mobileapp", "official", "prod", "client", "ipad"]
        let parts = n.split(separator: ".").dropFirst().map(String.init).filter { !generic.contains($0.lowercased()) }
        n = parts.last ?? n
    } else {
        n = n.components(separatedBy: CharacterSet(charactersIn: ":")).first ?? n
        n = n.components(separatedBy: " - ").first ?? n
    }
    return n.lowercased().filter { $0.isLetter || $0.isNumber }
}

/// "136 hours, 11 minutes" / "1 hour, 45 minutes" / "46 seconds" → seconds.
func parseDuration(_ s: String) -> Int {
    var total = 0
    let units: [(String, Int)] = [("hour", 3600), ("minute", 60), ("second", 1)]
    for part in s.components(separatedBy: ",") {
        let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard words.count >= 2, let n = Int(words[0]) else { continue }
        if let unit = units.first(where: { words[1].hasPrefix($0.0) }) { total += n * unit.1 }
    }
    return total
}

struct ServiceError: LocalizedError {
    var errorDescription: String?
}

/// Calls the Time service from a background thread and waits for its answer.
@discardableResult
func serviceCall(_ path: String, _ body: [String: Any] = [:]) throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "http://localhost:\(servicePort)\(path)")!, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "X-Time")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let done = DispatchSemaphore(value: 0)
    var result: Result<[String: Any], Error> = .failure(ServiceError(errorDescription: "The Time service didn't answer."))
    URLSession.shared.dataTask(with: req) { data, resp, err in
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let err { result = .failure(err) }
        else if (resp as? HTTPURLResponse)?.statusCode == 200 { result = .success(obj) }
        else { result = .failure(ServiceError(errorDescription: obj["error"] as? String ?? "The Time service refused.")) }
        done.signal()
    }.resume()
    done.wait()
    return try result.get()
}

/// Sends the list to the Time service.
func postScreenTimeItems(_ items: [ScreenTimeItem], done: @escaping (String?) -> Void) {
    var req = URLRequest(url: URL(string: "http://localhost:\(servicePort)/api/screentime/import")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "X-Time")
    req.httpBody = try? JSONEncoder().encode(["items": items])
    URLSession.shared.dataTask(with: req) { data, resp, err in
        var message: String?
        if let err { message = err.localizedDescription }
        else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            message = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String) ?? "Import failed (\(http.statusCode))."
        }
        DispatchQueue.main.async { done(message) }
    }.resume()
}
