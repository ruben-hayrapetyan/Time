import DeviceActivity
import FamilyControls
import Foundation
import Observation

struct UserError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor @Observable
final class AppModel {
    private(set) var state: State
    private(set) var authorized: Bool
    var message: String?
    /// Shown inside the emergency sheet, where an alert can't appear.
    var emergencyError: String?

    init() {
        state = Engine.reconcile()
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    var lock: Lock? { state.lock }

    /// Run when the app comes forward: catch up on anything the monitor may have missed.
    func refresh() {
        state = Engine.reconcile()
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if let l = state.lock {
            try? Engine.scheduleEnd(l)
            if let at = l.emergency?.unlockAt { try? Engine.scheduleEmergency(at: at) }
        }
    }

    func requestAccess() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            message = "Time needs Screen Time access to lock apps. \(error.localizedDescription)"
        }
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    /// What the app picker should start from: the running lock, or the next lock's picks.
    var pickerStart: FamilyActivitySelection { state.lock?.selection ?? state.selection }

    /// During a lock the picker can only add: anything unticked stays locked.
    func pick(_ sel: FamilyActivitySelection) {
        var s = Engine.load()
        if var l = s.lock {
            l.apps.formUnion(sel.applicationTokens)
            l.categories.formUnion(sel.categoryTokens)
            l.webDomains.formUnion(sel.webDomainTokens)
            if l.apps.count > Config.maxApps {
                message = "iOS can lock at most \(Config.maxApps) apps at once. Pick a category to cover more."
                return
            }
            s.lock = l
            s.selection = l.selection
        } else {
            s.selection = sel
        }
        commit(s)
    }

    func startLock(for length: TimeInterval) {
        var s = Engine.load()
        guard s.lock == nil else { return }
        let sel = s.selection
        guard sel.itemCount > 0 else { return fail("Pick at least one app first.") }
        guard sel.applicationTokens.count <= Config.maxApps else {
            return fail("iOS can lock at most \(Config.maxApps) apps at once. Pick a category to cover more.")
        }
        let now = Date()
        let length = min(max(length, Config.minLock), Config.maxLock)
        let l = Lock(startedAt: now, endsAt: now.addingTimeInterval(length),
                     apps: sel.applicationTokens, categories: sel.categoryTokens, webDomains: sel.webDomainTokens)
        s.lock = l
        commit(s)
        do { try Engine.scheduleEnd(l) } catch {
            message = "Locked, but iOS wouldn't schedule the unlock (\(error.localizedDescription)). Open Time after the timer ends to unlock."
        }
    }

    /// Adds time, never past 7 days from now.
    func extend(by t: TimeInterval) {
        var s = Engine.load()
        guard var l = s.lock else { return }
        let cap = Date().addingTimeInterval(Config.maxLock)
        guard l.endsAt < cap else { return fail("A lock can't run more than 7 days ahead.") }
        l.endsAt = min(l.endsAt.addingTimeInterval(t), cap)
        s.lock = l
        commit(s)
        try? Engine.scheduleEnd(l)
    }

    // MARK: Emergency unlock

    func emergencyStart(_ target: Target) {
        var s = Engine.load()
        guard var l = s.lock else { return }
        if l.emergency?.unlockAt != nil { return fail("An emergency unlock is already counting down.") }
        l.emergency = Emergency(target: target, challenge: Passage.make(), issuedAt: Date())
        s.lock = l
        commit(s)
    }

    func emergencySubmit(_ text: String) {
        emergencyError = nil
        var s = Engine.load()
        guard var l = s.lock, var e = l.emergency, let challenge = e.challenge else { return }
        guard Passage.normalize(text) == Passage.normalize(challenge) else {
            return emergencyFail("That doesn't match the passage exactly.")
        }
        let typed = Date().timeIntervalSince(e.issuedAt)
        guard typed >= Config.emergencyTyping else {
            return emergencyFail("That was too fast to have been typed (\(Int(typed))s). Type it by hand.")
        }
        let at = Date().addingTimeInterval(Config.emergencyCooldown)
        e.challenge = nil
        e.unlockAt = at
        l.emergency = e
        s.lock = l
        commit(s)
        do { try Engine.scheduleEmergency(at: at) } catch {
            message = "Accepted, but iOS wouldn't schedule it. Open Time once the wait is over to finish."
        }
    }

    func emergencyCancel() {
        var s = Engine.load()
        guard var l = s.lock else { return }
        l.emergency = nil
        s.lock = l
        commit(s)
        DeviceActivityCenter().stopMonitoring([Engine.emergencyActivity])
    }

    /// Called each second by the views, so an ending lock or cooldown takes effect on screen.
    func tick() {
        guard let l = state.lock else { return }
        let now = Date()
        if now >= l.endsAt || (l.emergency?.unlockAt.map { now >= $0 } ?? false) {
            state = Engine.reconcile()
        }
    }

    private func commit(_ s: State) {
        Engine.save(s)
        Engine.enforce(s)
        state = s
    }

    private func fail(_ m: String) { message = m }
    private func emergencyFail(_ m: String) { emergencyError = m }
}

