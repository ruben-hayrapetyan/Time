// Time.app: a native window around the Time service's control page, a menu bar
// countdown, and a one-click installer for the background service.
import AppKit
import WebKit

let servicePort = 7777
let serviceURL = URL(string: "http://localhost:\(servicePort)/")!
let statusURL = URL(string: "http://localhost:\(servicePort)/api/status")!
let installedPlist = "/Library/LaunchDaemons/com.time.blocker.plist"

struct ServiceStatus {
    var version: String
    var lockEndsAt: Double?
    var nowMs: Double
    var hard: Bool
}

func fetchStatus(_ done: @escaping (ServiceStatus?) -> Void) {
    var req = URLRequest(url: statusURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
    req.httpMethod = "GET"
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DispatchQueue.main.async { done(nil) }
        }
        let lock = obj["lock"] as? [String: Any]
        let s = ServiceStatus(
            version: obj["version"] as? String ?? "0",
            lockEndsAt: lock?["endsAt"] as? Double,
            nowMs: obj["now"] as? Double ?? Date().timeIntervalSince1970 * 1000,
            hard: lock?["hard"] as? Bool ?? false)
        DispatchQueue.main.async { done(s) }
    }.resume()
}

func countdown(_ ms: Double) -> String {
    let s = max(0, Int((ms / 1000).rounded(.up)))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    var lastStatus: ServiceStatus?
    var statusFetchedAt = Date()
    var showingSetup = false
    var installing = false

    var bundleVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var payloadDir: URL { Bundle.main.resourceURL!.appendingPathComponent("payload") }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        buildStatusItem()
        route()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.renderStatusItem() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: window

    func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "time")
        web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Time"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 560)
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.071, green: 0.153, blue: 0.122, alpha: 1)
                : NSColor(srgbRed: 0.875, green: 0.898, blue: 0.882, alpha: 1)
        }
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TimeMain")
        if !window.setFrameUsingName("TimeMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Decide between the control page and the setup screen.
    func route() {
        fetchStatus { [weak self] s in
            guard let self else { return }
            self.lastStatus = s
            self.statusFetchedAt = Date()
            let installed = FileManager.default.fileExists(atPath: installedPlist)
            if let s, s.version == self.bundleVersion || s.lockEndsAt != nil {
                // Up to date, or locked (updates wait until the lock ends).
                self.showingSetup = false
                self.web.load(URLRequest(url: serviceURL))
            } else if installed && s == nil {
                // Installed but not answering yet (e.g. just booted): try again shortly.
                self.showSetup(mode: "starting")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.route() }
            } else {
                self.showSetup(mode: s == nil ? "install" : "update")
            }
        }
    }

    func showSetup(mode: String) {
        showingSetup = true
        let url = Bundle.main.url(forResource: "setup", withExtension: "html")!
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "v", value: bundleVersion)]
        web.loadFileURL(comps.url!, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: installer

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "time", let cmd = message.body as? String, cmd == "install" { runInstaller() }
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func runAdmin(_ script: String, prompt: String, done: @escaping (Bool, String) -> Void) {
        let cmd = "export SUDO_USER=\(shellQuote(NSUserName())) TIME_NO_OPEN=1; \(script) 2>&1"
        let source = "do shell script \(appleScriptString(cmd)) with administrator privileges with prompt \(appleScriptString(prompt))"
        DispatchQueue.global().async {
            var err: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                if let err {
                    let canceled = (err[NSAppleScript.errorNumber] as? Int) == -128
                    done(false, canceled ? "canceled" : (err[NSAppleScript.errorMessage] as? String ?? "Unknown error"))
                } else {
                    done(true, out?.stringValue ?? "")
                }
            }
        }
    }

    func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func runInstaller() {
        guard !installing else { return }
        installing = true
        web.evaluateJavaScript("setBusy(true)")
        let script = "cd \(shellQuote(payloadDir.path)) && /bin/bash ./install.sh"
        runAdmin(script, prompt: "Time needs your password to install its background service.") { [weak self] ok, out in
            guard let self else { return }
            self.installing = false
            if ok {
                self.route()
            } else {
                let msg = out == "canceled" ? "Install canceled. Nothing was changed." : out
                self.web.evaluateJavaScript("setBusy(false); showError(\(self.jsString(msg)))")
            }
        }
    }

    @objc func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Time's background service?"
        alert.informativeText = "This removes all blocks and the timekeeper account. It won't run while a lock is active."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let script = "cd \(shellQuote(payloadDir.path)) && /bin/bash ./uninstall.sh"
        runAdmin(script, prompt: "Time needs your password to uninstall its background service.") { [weak self] ok, out in
            if !ok && out == "canceled" { return }
            let done = NSAlert()
            done.messageText = ok ? "Time's background service is uninstalled." : "Couldn't uninstall."
            done.informativeText = ok ? "You can drag Time.app to the Trash." : out
            done.runModal()
            self?.route()
        }
    }

    func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(data: data, encoding: .utf8)!.dropFirst().dropLast().description
    }

    // MARK: web view

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let parts = message.components(separatedBy: "\n\n")
        let a = NSAlert()
        a.messageText = parts[0]
        a.informativeText = parts.dropFirst().joined(separator: "\n\n")
        a.addButton(withTitle: "Lock")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { route() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { route() }

    // Keep the window on the control page; open anything else in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL || (url.host == "localhost" && url.port == servicePort) { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: menu bar countdown

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Time", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Time", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        renderStatusItem()
    }

    @objc func openFromMenu() { showWindow() }

    func poll() {
        fetchStatus { [weak self] s in
            guard let self else { return }
            let wasLocked = self.lastStatus?.lockEndsAt != nil
            self.lastStatus = s
            self.statusFetchedAt = Date()
            self.renderStatusItem()
            // Service came up, or a lock ended and an update is waiting.
            if self.showingSetup && !self.installing && s != nil { self.route() }
            if wasLocked && s?.lockEndsAt == nil && s?.version != self.bundleVersion { self.route() }
        }
    }

    func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        if let s = lastStatus, let ends = s.lockEndsAt {
            let now = s.nowMs + Date().timeIntervalSince(statusFetchedAt) * 1000
            button.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")
            button.title = " " + countdown(ends - now)
        } else {
            button.image = NSImage(systemSymbolName: lastStatus == nil ? "lock.slash" : "lock.open", accessibilityDescription: "Time")
            button.title = ""
        }
    }

    // MARK: main menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Time", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Uninstall Background Service…", action: #selector(uninstall), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Time", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Time", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        viewItem.submenu = view
        main.addItem(viewItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc func reload() { route() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
