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
    var blocks: [Block] = []
    var passcodeHeld = false

    struct Block {
        var screenTimeName: String
        var enabled: Bool
        var locked: Bool
    }
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
            hard: lock?["hard"] as? Bool ?? false,
            blocks: (obj["blocks"] as? [[String: Any]] ?? []).compactMap { b in
                (b["screenTimeName"] as? String).map { .init(screenTimeName: $0, enabled: b["enabled"] as? Bool ?? false, locked: b["locked"] as? Bool ?? false) }
            },
            passcodeHeld: (obj["screenTime"] as? [String: Any])?["passcodeHeld"] as? Bool ?? false)
        DispatchQueue.main.async { done(s) }
    }.resume()
}

/// Appends a line to ~/Library/Application Support/Time/app.log (Screen Time changes, so failures can be traced later).
func appLog(_ line: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Time/app.log")
    let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    } else {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
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

    var bundleVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "TimeBuild") as? String
        return b.map { "\(v)+\($0)" } ?? v
    }
    var displayVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
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
        comps.queryItems = [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "v", value: displayVersion)]
        web.loadFileURL(comps.url!, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: installer

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "time", let cmd = message.body as? String else { return }
        if cmd == "install" { runInstaller() }
        if cmd == "refreshScreenTime" { refreshScreenTime() }
    }

    /// System Settings is being driven (reading the list or changing limits); one job at a time.
    var usingSettings = false

    /// Reads the Screen Time list in System Settings and hands it to the service.
    func refreshScreenTime() {
        guard !usingSettings else { return }
        usingSettings = true
        web.evaluateJavaScript("window.screenTimeBusy && screenTimeBusy(true)")
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<[ScreenTimeItem], Error>
            do { result = .success(try ScreenTimeReader().readAll()) } catch { result = .failure(error) }
            DispatchQueue.main.async {
                switch result {
                case .success(let items):
                    postScreenTimeItems(items) { err in
                        self.usingSettings = false
                        self.web.evaluateJavaScript("window.screenTimeDone && screenTimeDone(\(err.map(self.jsString) ?? "null"), \(items.count))")
                    }
                case .failure(let error):
                    self.usingSettings = false
                    self.web.evaluateJavaScript("window.screenTimeDone && screenTimeDone(\(self.jsString(error.localizedDescription)), 0)")
                }
            }
        }
    }

    // MARK: phone limits

    /// Screen Time names of the apps Time has an App Limit for, mapped to that limit's title.
    var phoneLimits: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "phoneLimits") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "phoneLimits") }
    }
    var phoneFailedAt: [String: Date] = [:]
    /// The running lock's Screen Time passcode. Only in memory (the service keeps the saved copy and
    /// won't hand it out mid-lock), so after a restart Time leaves Screen Time alone until the lock ends.
    var lockPasscode: String?
    var lockPasscodeOn = false

    /// How long since the last mouse or keyboard input.
    var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Locking an app makes Screen Time block it on every device sharing Screen Time (iPhone, iPad):
    /// Time turns on a random Screen Time passcode, then adds a 1-minute daily App Limit set to
    /// "Block at end of limit", which Screen Time only offers while a passcode is on and which takes
    /// "Ignore Limit" away. The service keeps the code until the lock ends; then Time turns the
    /// passcode off and removes every 1-minute limit it made for those apps. A limit stays while its
    /// block is on (so "keep on after the lock" keeps it on the phone too).
    ///
    /// Driving System Settings needs the screen for a few seconds, so this only starts when the mouse
    /// and keyboard are at rest: right after Lock is clicked (2 s), otherwise after 30 s idle.
    func syncPhoneLimits(_ s: ServiceStatus) {
        // The service answered, so this runs even on the update screen (a lock's passcode must still come off).
        guard !usingSettings, !installing else { return }
        let locked = s.lockEndsAt != nil
        if !locked && !s.passcodeHeld { lockPasscode = nil; lockPasscodeOn = false }
        let have = phoneLimits
        let want = Set(s.blocks.filter { $0.enabled && ($0.locked || have[$0.screenTimeName] != nil) }.map(\.screenTimeName))
        let retryable = { (name: String) in Date().timeIntervalSince(self.phoneFailedAt[name] ?? .distantPast) > 600 }
        // Lock start (or a retry): passcode first. A code the service holds that this session didn't
        // confirm gets retried; one from before a restart is unknown, and Screen Time stays as it is.
        let setup = locked && !want.isEmpty && !lockPasscodeOn && (!s.passcodeHeld || lockPasscode != nil) && retryable("passcode")
        let add = locked && (setup || lockPasscodeOn) ? want.subtracting(have.keys).filter(retryable).sorted() : []
        let cleanup = !locked && s.passcodeHeld && retryable("passcode")
        let remove = !locked ? Set(have.keys).subtracting(want).filter(retryable).sorted() : []
        if !setup && add.isEmpty && !cleanup && remove.isEmpty { return }
        if idleSeconds < (setup ? 2 : 30) { return }

        usingSettings = true
        web.evaluateJavaScript("window.phoneSyncBusy && phoneSyncBusy(true)")
        let heldBefore = s.passcodeHeld
        DispatchQueue.global(qos: .userInitiated).async {
            let writer = ScreenTimeWriter()
            var errors: [String] = [], done: [String] = []
            appLog("sync: setup \(setup) add \(add) cleanup \(cleanup) remove \(remove)")
            let fail = { (key: String, what: String, error: Error) in
                appLog("failed: \(what): \(error.localizedDescription)")
                errors.append("\(what): \(error.localizedDescription)")
                DispatchQueue.main.sync { self.phoneFailedAt[key] = Date() }
            }
            if setup {
                do {
                    let code = DispatchQueue.main.sync { self.lockPasscode } ?? String(format: "%04d", Int.random(in: 0...9999))
                    DispatchQueue.main.sync { self.lockPasscode = code }
                    // The service saves the code to disk before it goes anywhere near Screen Time.
                    try serviceCall("/api/screentime/passcode", ["code": code])
                    try writer.setPasscode(code, retrying: heldBefore)
                    DispatchQueue.main.sync { self.lockPasscodeOn = true }
                    done.append("Screen Time passcode on until the lock ends")
                } catch { fail("passcode", "Couldn't turn on a Screen Time passcode", error) }
            }
            // Without the passcode on, a limit could just be ignored, so limits wait for it.
            let code = DispatchQueue.main.sync { self.lockPasscodeOn ? self.lockPasscode : nil }
            for name in add where code != nil {
                do {
                    let title = try writer.addLimit(name, passcode: code)
                    DispatchQueue.main.sync { self.phoneLimits[name] = title }
                    done.append("\(name) blocked after 1 minute a day on all your devices")
                } catch { fail(name, "Couldn't add a Screen Time limit for \(name)", error) }
            }
            var unlocked = !heldBefore
            if cleanup {
                do {
                    let code = try serviceCall("/api/screentime/passcode/reveal")["code"] as? String ?? ""
                    try writer.removePasscode(code)
                    try serviceCall("/api/screentime/passcode/forget", ["code": code])
                    unlocked = true
                    DispatchQueue.main.sync { self.lockPasscode = nil; self.lockPasscodeOn = false }
                    done.append("Screen Time passcode turned off")
                } catch { fail("passcode", "Couldn't turn off Time's Screen Time passcode", error) }
            }
            for name in remove where unlocked {
                do {
                    let n = try writer.removeLimits(have[name]!)
                    DispatchQueue.main.sync { self.phoneLimits[name] = nil }
                    done.append("removed \(n == 1 ? "the limit" : "\(n) limits") for \(name)")
                } catch { fail(name, "Couldn't remove the Screen Time limit for \(name)", error) }
            }
            writer.ui.finish()
            if !done.isEmpty { appLog("done: \(done.joined(separator: "; "))") }
            DispatchQueue.main.async {
                self.usingSettings = false
                let err = errors.isEmpty ? "null" : self.jsString(errors.joined(separator: " "))
                let ok = done.isEmpty ? "null" : self.jsString(done.joined(separator: "; ").prefix(1).uppercased() + done.joined(separator: "; ").dropFirst() + ".")
                self.web.evaluateJavaScript("window.phoneSyncDone && phoneSyncDone(\(err), \(ok))")
            }
        }
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
            if let s { self.syncPhoneLimits(s) }
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

// Developer checks, compiled in only by `./build-app.sh --dev`. They work System Settings with Time's
// Accessibility access, so in a normal build any program that can launch Time could use them.
#if TIME_DEVTOOLS
if CommandLine.arguments.contains("--read-screentime") {
    // Developer check: run the real reader and save what it found.
    let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Time/screentime-read.json")
    do {
        let items = try ScreenTimeReader().readAll()
        try JSONEncoder().encode(items).write(to: out)
    } catch {
        try? Data("{\"error\": \"\(error.localizedDescription)\"}".utf8).write(to: out)
    }
    exit(0)
}

let writerFlags = ["--add-limit", "--add-blocking-limit", "--remove-limit", "--set-passcode", "--remove-passcode"]
if let i = CommandLine.arguments.firstIndex(where: writerFlags.contains), i + 1 < CommandLine.arguments.count {
    // Developer check: add or remove one of Time's 1-minute limits, or its passcode, and save the outcome.
    let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Time/limit-write.txt")
    let writer = ScreenTimeWriter(), name = CommandLine.arguments[i + 1]
    var result: String
    do {
        switch CommandLine.arguments[i] {
        case "--add-limit": result = "added: " + (try writer.addLimit(name))
        case "--add-blocking-limit":
            // "<passcode>:<app>" — the passcode must already be on.
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            result = "added blocking: " + (try writer.addLimit(parts.count > 1 ? parts[1] : "", passcode: parts[0]))
        case "--remove-limit": result = "removed \(try writer.removeLimits(name)): \(name)"
        case "--set-passcode": try writer.setPasscode(name); result = "passcode on"
        default: try writer.removePasscode(name); result = "passcode off"
        }
    } catch { result = "error: \(error.localizedDescription)" }
    writer.ui.finish()
    try? result.write(to: out, atomically: true, encoding: .utf8)
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--ax") {
    runAXSteps(Array(CommandLine.arguments[(i + 1)...]))
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
