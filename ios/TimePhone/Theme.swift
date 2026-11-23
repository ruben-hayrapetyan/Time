// Time's look on the phone: deep enamel, a brass dial, soft glass cards.
import SwiftUI

enum Theme {
    static let enamel = Color(red: 0.075, green: 0.15, blue: 0.122)
    static let enamelDeep = Color(red: 0.027, green: 0.055, blue: 0.045)
    static let brass = Color(red: 0.85, green: 0.68, blue: 0.36)
    static let brassLight = Color(red: 0.96, green: 0.86, blue: 0.62)
    static let brassDark = Color(red: 0.62, green: 0.46, blue: 0.2)
    static let ink = Color(red: 0.06, green: 0.08, blue: 0.07)
    static let text = Color.white
    static let soft = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.35)
    static let line = Color.white.opacity(0.09)
    static let alarm = Color(red: 0.92, green: 0.45, blue: 0.35)

    static let brassFill = LinearGradient(colors: [brassLight, brass, brassDark], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The background: a dark enamel gradient with a brass glow that breathes while a lock runs.
struct Backdrop: View {
    var locked: Bool
    @State private var breathe = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.enamel, Theme.enamelDeep], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.brass.opacity(locked ? 0.28 : 0.10), .clear],
                           center: .init(x: 0.5, y: 0.22), startRadius: 0, endRadius: breathe ? 420 : 340)
            RadialGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.38).opacity(0.25), .clear],
                           center: .init(x: 0.1, y: 1.0), startRadius: 0, endRadius: 400)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: locked)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// A frosted card.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.line))
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.faint)
    }
}

/// A small pill button, filled when selected.
struct Chip: View {
    var title: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(selected ? Theme.ink : Theme.text)
                .background {
                    Capsule().fill(selected ? AnyShapeStyle(Theme.brassFill) : AnyShapeStyle(Color.white.opacity(0.07)))
                }
                .overlay(Capsule().strokeBorder(selected ? .clear : Theme.line))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct PrimaryButton: View {
    var title: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .foregroundStyle(Theme.ink)
                .background(Theme.brassFill, in: Capsule())
                .shadow(color: Theme.brass.opacity(0.35), radius: 16, y: 6)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct SecondaryButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundStyle(Theme.text)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
