// Woken by DeviceActivity when a scheduled interval starts or ends, even with the app closed.
// The end-of-lock and end-of-cooldown moments are interval ends; reconcile does the rest.
import DeviceActivity
import Foundation

final class MonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        Engine.enforce(Engine.load())
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let s = Engine.reconcile()
        // Woken a little early (or the lock was extended): look again at the new moment.
        guard let l = s.lock else { return }
        if activity == Engine.endActivity { try? Engine.scheduleEnd(l) }
        if activity == Engine.emergencyActivity, let at = l.emergency?.unlockAt { try? Engine.scheduleEmergency(at: at) }
    }
}
