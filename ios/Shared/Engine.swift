// The lock itself, shared by the app and its two extensions.
// State lives in the App Group so the DeviceActivity monitor can end the lock (and finish an
// emergency unlock) at the right moment even when the app isn't running.
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

enum Config {
    static let appGroup = "group.com.rubenhayrapetyan.time"
    static let minLock: TimeInterval = 15 * 60
    static let maxLock: TimeInterval = 7 * 24 * 3600
    static let emergencyTyping: TimeInterval = 90
    static let emergencyCooldown: TimeInterval = 20 * 60
    static let passageWords = 50
    /// Apple caps a store's shielded apps at 50.
    static let maxApps = 50
}

/// What an emergency unlock lets go of: the whole lock, or one item in it.
enum Target: Codable, Hashable {
    case everything
    case app(ApplicationToken)
    case category(ActivityCategoryToken)
    case web(WebDomainToken)
}

struct Emergency: Codable {
    var target: Target
    /// The passage to type; nil once it's been accepted and the cooldown is running.
    var challenge: String?
    var issuedAt: Date
    var unlockAt: Date?
}

struct Lock: Codable {
    var startedAt: Date
    var endsAt: Date
    var apps: Set<ApplicationToken>
    var categories: Set<ActivityCategoryToken>
    var webDomains: Set<WebDomainToken>
    var emergency: Emergency?

    var isEmpty: Bool { apps.isEmpty && categories.isEmpty && webDomains.isEmpty }
    var itemCount: Int { apps.count + categories.count + webDomains.count }

    var selection: FamilyActivitySelection {
        var s = FamilyActivitySelection()
        s.applicationTokens = apps
        s.categoryTokens = categories
        s.webDomainTokens = webDomains
        return s
    }
}

struct State: Codable {
    /// What's picked for the next lock.
    var selection = FamilyActivitySelection()
    var lock: Lock?
}

enum Engine {
    static let store = ManagedSettingsStore(named: .init("time.lock"))
    static let endActivity = DeviceActivityName("time.end")
    static let emergencyActivity = DeviceActivityName("time.emergency")
    private static let key = "state.v1"

    static var defaults: UserDefaults { UserDefaults(suiteName: Config.appGroup) ?? .standard }

    static func load() -> State {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }

    static func save(_ s: State) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }

    /// Makes the shields match the state: on for everything in a running lock, off otherwise.
    static func enforce(_ s: State) {
        guard let l = s.lock else {
            store.clearAllSettings()
            return
        }
        store.shield.applications = l.apps.isEmpty ? nil : l.apps
        store.shield.applicationCategories = l.categories.isEmpty ? nil : .specific(l.categories)
        store.shield.webDomains = l.webDomains.isEmpty ? nil : l.webDomains
        store.shield.webDomainCategories = l.categories.isEmpty ? nil : .specific(l.categories)
        // Deleting Time (or a locked app) would drop the shields, and so would winding the clock.
        store.application.denyAppRemoval = true
        store.dateAndTime.requireAutomaticDateAndTime = true
    }

    /// Ends the lock if its time is up and finishes an emergency unlock whose cooldown is over,
    /// then saves and enforces. Safe to call any time, from the app or the monitor.
    @discardableResult
    static func reconcile(now: Date = Date()) -> State {
        var s = load()
        if var l = s.lock {
            if let e = l.emergency, let at = e.unlockAt, at <= now.addingTimeInterval(5) {
                switch e.target {
                case .everything: l.apps = []; l.categories = []; l.webDomains = []
                case .app(let t): l.apps.remove(t)
                case .category(let t): l.categories.remove(t)
                case .web(let t): l.webDomains.remove(t)
                }
                l.emergency = nil
            }
            s.lock = (l.isEmpty || now >= l.endsAt.addingTimeInterval(-5)) ? nil : l
            if s.lock == nil { DeviceActivityCenter().stopMonitoring([endActivity, emergencyActivity]) }
        }
        save(s)
        enforce(s)
        return s
    }

    // MARK: Scheduling
    //
    // DeviceActivity wakes the monitor at the end of an interval. Intervals must be at least
    // 15 minutes and can't be too long, so each one covers only the last stretch before its moment.

    static func scheduleEnd(_ l: Lock) throws {
        try schedule(endActivity, at: l.endsAt)
    }

    static func scheduleEmergency(at date: Date) throws {
        try schedule(emergencyActivity, at: date)
    }

    private static func schedule(_ name: DeviceActivityName, at date: Date) throws {
        let center = DeviceActivityCenter()
        center.stopMonitoring([name])
        let now = Date()
        // A minute late is fine; a minute early would leave the lock on until the next check.
        let fire = date.addingTimeInterval(60)
        let start = max(now, fire.addingTimeInterval(-16 * 60))
        let end = max(fire, start.addingTimeInterval(15 * 60 + 30))
        let cal = Calendar.current
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents(parts, from: start),
            intervalEnd: cal.dateComponents(parts, from: end),
            repeats: false)
        try center.startMonitoring(name, during: schedule)
    }
}

enum Passage {
    static let words = """
    anchor autumn balance banner basket beacon blanket border bottle branch breeze bridge bright bucket
    cabin candle canvas carpet castle cellar charcoal circle climate cobalt copper corner cotton county
    crystal current custom dancer desert detail dinner divide doctor dollar donkey drawer driver eagle
    easel effort elbow empire engine evening fabric falcon farmer feather fence fiction filter finger
    forest fossil frozen garden gentle glacier global gravel guitar hammer harbor harvest helmet hollow
    honest horizon humble hunter island jacket jungle kettle kitten ladder lantern layer legend lemon
    letter lizard lumber magnet mammal marble meadow melody mirror modest morning mosaic motion napkin
    narrow nature needle network noble number object ocean office orange orbit outline oxygen paddle
    palace pencil pepper planet pocket poetry powder prairie puzzle quarter quiet rabbit radius random
    ribbon riddle rocket rubber saddle salmon sandal season shadow signal silver singer sketch slogan
    socket spider spiral spring statue stream studio summit sunset switch symbol tablet talent temple
    thunder ticket timber tissue tomato tunnel turtle umbrella valley velvet vessel violin voyage walnut
    wander window winter wizard wonder yellow zipper
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    static func make(_ n: Int = Config.passageWords) -> String {
        (0..<n).map { _ in words.randomElement()! }.joined(separator: " ")
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum Fmt {
    /// "2d 14:03:22", "14:03:22", "3:22".
    static func countdown(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60, sec = s % 60
        if d > 0 { return String(format: "%dd %02d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    /// "15m", "4h", "1d 6h".
    static func length(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60, d = h / 24
        if d == 0 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h"
    }

    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today at \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) + " at \(time)"
    }
}
