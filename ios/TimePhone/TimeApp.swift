import FamilyControls
import SwiftUI

@main
struct TimeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.brass)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var model = model
        ZStack {
            Backdrop(locked: model.lock != nil)
            Group {
                if !model.authorized {
                    OnboardingView()
                } else if model.lock != nil {
                    LockedView()
                } else {
                    IdleView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.lock != nil)
        .animation(.easeInOut, value: model.authorized)
        .onChange(of: phase) { _, p in if p == .active { model.refresh() } }
        .alert("Time", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Dial(progress: appeared ? 0.75 : 0, glowing: true) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.brassFill)
            }
            .frame(width: 230)
            .padding(.bottom, 40)

            Text("Time")
                .font(Theme.display(44, .bold))
            Text("Lock the apps that eat your day,\nwith a timer you can't talk your way past.")
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.soft)
                .padding(.top, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Point(icon: "hand.raised.fill", text: "Locked apps show a shield instead of opening.")
                Point(icon: "timer", text: "Locks run up to 7 days, and can't be shortened.")
                Point(icon: "keyboard", text: "The only way out early is a slow, hand-typed emergency unlock.")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 32)

            PrimaryButton(title: "Allow Screen Time access") {
                Task { await model.requestAccess() }
            }
            Text("Your choices stay on this iPhone. Time has no account and sends nothing anywhere.")
                .font(.footnote)
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
        .padding(24)
        .onAppear { withAnimation(.easeOut(duration: 1.6).delay(0.2)) { appeared = true } }
    }

    private struct Point: View {
        var icon: String
        var text: String
        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.brass)
                    .frame(width: 34, height: 34)
                    .background(Theme.brass.opacity(0.12), in: Circle())
                Text(text).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.85))
            }
        }
    }
}
