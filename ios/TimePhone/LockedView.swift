import FamilyControls
import SwiftUI

/// A lock is running: the countdown, what's locked, and the ways to add to it.
struct LockedView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false
    @State private var picked = FamilyActivitySelection()
    @State private var emergency = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            if let l = model.lock {
                content(l, now: now)
                    .onChange(of: now) { _, _ in model.tick() }
            }
        }
        .familyActivityPicker(isPresented: $picking, selection: $picked)
        .onChange(of: picking) { _, open in if !open { model.pick(picked) } }
        .sheet(isPresented: $emergency) { EmergencyView() }
    }

    private func content(_ l: Lock, now: Date) -> some View {
        let total = l.endsAt.timeIntervalSince(l.startedAt)
        let left = l.endsAt.timeIntervalSince(now)
        return ScrollView {
            VStack(spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Locked").font(Theme.display(34, .bold))
                        Text("Unlocks \(Fmt.when(l.endsAt))").font(.system(size: 15)).foregroundStyle(Theme.soft)
                    }
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 42, height: 42)
                        .background(Theme.brassFill, in: Circle())
                        .shadow(color: Theme.brass.opacity(0.5), radius: 10)
                        .symbolEffect(.pulse, options: .repeating)
                }

                Dial(progress: total > 0 ? left / total : 0, glowing: true) {
                    VStack(spacing: 6) {
                        SectionLabel(text: "Time left")
                        Text(Fmt.countdown(left))
                            .font(Theme.display(left >= 86400 ? 36 : 46, .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .padding(.horizontal, 40)
                        Text("of \(Fmt.length(total))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.soft)
                    }
                }
                .frame(maxWidth: 300)
                .padding(.vertical, 4)

                if let e = l.emergency, let at = e.unlockAt {
                    cooldown(e, at: at, now: now)
                }

                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(text: "Locked")
                            Text(l.selection.summary).font(.system(size: 17, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        Button {
                            picked = model.pickerStart
                            picking = true
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.brass.opacity(0.15), in: Capsule())
                    }
                    TokenIcons(selection: l.selection)
                }

                Card {
                    SectionLabel(text: "Add time")
                    HStack(spacing: 8) {
                        ForEach([(1800.0, "+30m"), (3600, "+1h"), (4 * 3600, "+4h"), (86400, "+1d")], id: \.0) { t, label in
                            Chip(title: label) { model.extend(by: t) }
                        }
                    }
                    Text("You can always add time. You can't take it away.")
                        .font(.footnote).foregroundStyle(Theme.faint)
                }

                if l.emergency?.unlockAt == nil {
                    Button("Emergency unlock") { emergency = true }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 6)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func cooldown(_ e: Emergency, at: Date, now: Date) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "hourglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.alarm)
                    .frame(width: 40, height: 40)
                    .background(Theme.alarm.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        switch e.target {
                        case .everything: Text("Ending the whole lock")
                        case .app(let t): HStack(spacing: 6) { Text("Unlocking"); Label(t).labelStyle(.titleOnly) }
                        case .category(let t): HStack(spacing: 6) { Text("Unlocking"); Label(t).labelStyle(.titleOnly) }
                        case .web(let t): HStack(spacing: 6) { Text("Unlocking"); Label(t).labelStyle(.titleOnly) }
                        }
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("in \(Fmt.countdown(at.timeIntervalSince(now)))")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(Theme.soft)
                }
                Spacer()
            }
            SecondaryButton(title: "Stay locked", systemImage: "lock") { model.emergencyCancel() }
        }
    }
}
