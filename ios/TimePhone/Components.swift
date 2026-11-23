import FamilyControls
import ManagedSettings
import SwiftUI

/// The vault time-lock dial: a ring of ticks with a brass arc for the time that's left.
struct Dial<Center: View>: View {
    var progress: Double
    var glowing: Bool
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.01)],
                                     center: .center, startRadius: 0, endRadius: 180))
                .overlay(Circle().strokeBorder(Theme.line))
                .padding(26)

            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2
                let n = 120
                for i in 0..<n {
                    let f = Double(i) / Double(n)
                    let a = f * 2 * .pi - .pi / 2
                    let major = i % 10 == 0
                    let outer = r - 2, inner = r - (major ? 16 : 9)
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
                    p.addLine(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
                    let lit = f < progress
                    ctx.stroke(p, with: .color(lit ? Theme.brass.opacity(major ? 1 : 0.75) : Color.white.opacity(major ? 0.28 : 0.12)),
                               style: StrokeStyle(lineWidth: major ? 2.5 : 1.5, lineCap: .round))
                }
            }

            Circle()
                .trim(from: 0, to: max(0.002, progress))
                .stroke(Theme.brassFill, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(26)
                .shadow(color: Theme.brass.opacity(glowing ? 0.7 : 0.25), radius: glowing ? 14 : 6)
                .opacity(progress > 0 ? 1 : 0)

            center
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)
    }
}

/// A button you hold down to confirm, filling with brass as you hold.
struct HoldButton: View {
    var title: String
    var holdingTitle = "Keep holding…"
    var enabled = true
    var duration: Double = 1.2
    var action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var pressing = false
    @State private var fired = 0

    var body: some View {
        let label = HStack(spacing: 10) {
            Image(systemName: "lock.fill")
            Text(pressing ? holdingTitle : title)
        }
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .frame(maxWidth: .infinity)

        ZStack {
            Capsule().fill(Theme.brass.opacity(0.14))
            Capsule().strokeBorder(Theme.brass.opacity(0.45), lineWidth: 1)
            GeometryReader { g in
                Capsule()
                    .fill(Theme.brassFill)
                    .frame(width: g.size.height + (g.size.width - g.size.height) * progress)
                    .opacity(progress > 0.001 ? 1 : 0)
            }
            label.foregroundStyle(Theme.brassLight)
            label.foregroundStyle(Theme.ink)
                .mask(alignment: .leading) {
                    GeometryReader { g in
                        Rectangle().frame(width: progress > 0.001 ? g.size.height + (g.size.width - g.size.height) * progress : 0)
                    }
                }
        }
        .frame(height: 64)
        .shadow(color: Theme.brass.opacity(pressing ? 0.5 : 0.15), radius: pressing ? 22 : 10)
        .opacity(enabled ? 1 : 0.35)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 60) {
            guard enabled else { return }
            fired += 1
            action()
            withAnimation(.easeOut(duration: 0.3)) { progress = 0 }
        } onPressingChanged: { p in
            guard enabled else { return }
            pressing = p
            withAnimation(p ? .linear(duration: duration) : .spring(response: 0.35, dampingFraction: 0.8)) { progress = p ? 1 : 0 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, new in new }
        .sensoryFeedback(.success, trigger: fired)
    }
}

/// The icons of the picked apps, categories, and sites.
struct TokenIcons: View {
    var selection: FamilyActivitySelection
    var limit = 15

    var body: some View {
        let apps = Array(selection.applicationTokens)
        let cats = Array(selection.categoryTokens)
        let webs = Array(selection.webDomainTokens)
        let total = apps.count + cats.count + webs.count
        let shown = min(total, limit)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
            ForEach(0..<shown, id: \.self) { i in
                Group {
                    if i < apps.count { Label(apps[i]) }
                    else if i < apps.count + cats.count { Label(cats[i - apps.count]) }
                    else { Label(webs[i - apps.count - cats.count]) }
                }
                .labelStyle(.iconOnly)
                .scaleEffect(1.6)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if total > shown {
                Text("+\(total - shown)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.soft)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

extension FamilyActivitySelection {
    var itemCount: Int { applicationTokens.count + categoryTokens.count + webDomainTokens.count }

    var summary: String {
        var parts: [String] = []
        if !applicationTokens.isEmpty { parts.append("\(applicationTokens.count) app\(applicationTokens.count == 1 ? "" : "s")") }
        if !categoryTokens.isEmpty { parts.append("\(categoryTokens.count) categor\(categoryTokens.count == 1 ? "y" : "ies")") }
        if !webDomainTokens.isEmpty { parts.append("\(webDomainTokens.count) site\(webDomainTokens.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing picked yet" : parts.joined(separator: " · ")
    }
}
