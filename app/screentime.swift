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
    case notTrusted, notFound(String)
    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Time needs Accessibility access: System Settings → Privacy & Security → Accessibility → Time."
        case .notFound(let what): return "Couldn't find \(what) in Screen Time settings."
        }
    }
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

    /// Navigates to Screen Time's top page, whatever subpage System Settings was left on.
    func goToScreenTimeHome() throws {
        ui.open()
        for _ in 0..<4 {
            if ui.waitFor(1.5, { AX.role($0) == "AXButton" && AX.label($0) == "App & Website Activity" }) != nil { return }
            if let back = ui.waitFor(1, { AX.str($0, kAXIdentifierAttribute as String) == "go back" }) { AX.press(back) }
            Thread.sleep(forTimeInterval: 0.8)
        }
        throw ScreenTimeError.notFound("the Screen Time page")
    }

    func readActivity() throws -> [ScreenTimeItem] {
        guard AX.trusted(prompt: true) else { throw ScreenTimeError.notTrusted }
        try goToScreenTimeHome()
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
        try goToScreenTimeHome()
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
