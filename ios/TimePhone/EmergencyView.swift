import FamilyControls
import ManagedSettings
import SwiftUI

/// The one early way out: type a 50-word passage by hand (no pasting, at least 90 seconds),
/// then wait 20 minutes. It can end the whole lock or let go of one item.
struct EmergencyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var target: Target = .everything
    @State private var typed = ""
    @State private var pasteWarning = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop(locked: true)
                if let l = model.lock {
                    if let e = l.emergency, let challenge = e.challenge {
                        typing(challenge, issuedAt: e.issuedAt)
                    } else if l.emergency?.unlockAt != nil {
                        accepted
                    } else {
                        choose(l)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stay locked") {
                        model.emergencyCancel()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Emergency unlock")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationBackground(Theme.enamelDeep)
        .interactiveDismissDisabled(model.lock?.emergency?.challenge != nil)
    }

    private func choose(_ l: Lock) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("If you really need out, you'll type a 50-word passage by hand, then wait 20 more minutes with everything still locked. You can back out at any point.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.soft)

                Card {
                    SectionLabel(text: "Unlock")
                    row(.everything) { Text("Everything").font(.system(size: 16, weight: .semibold, design: .rounded)) }
                    ForEach(Array(l.apps), id: \.self) { t in row(.app(t)) { Label(t) } }
                    ForEach(Array(l.categories), id: \.self) { t in row(.category(t)) { Label(t) } }
                    ForEach(Array(l.webDomains), id: \.self) { t in row(.web(t)) { Label(t) } }
                }

                Text(target == .everything
                     ? "Ends the whole lock."
                     : "Only this one unlocks. Everything else stays locked until the timer ends.")
                    .font(.footnote).foregroundStyle(Theme.faint)

                PrimaryButton(title: "Start typing") {
                    typed = ""
                    model.emergencyStart(target)
                    focused = true
                }
            }
            .padding(20)
        }
    }

    private func row<L: View>(_ t: Target, @ViewBuilder label: () -> L) -> some View {
        Button {
            target = t
        } label: {
            HStack {
                label()
                Spacer()
                Image(systemName: target == t ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(target == t ? Theme.brass : Theme.faint)
                    .font(.system(size: 20))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: target)
    }

    private func typing(_ challenge: String, issuedAt: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    SectionLabel(text: "Type this")
                    Text(challenge)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .lineSpacing(4)
                }

                TextEditor(text: $typed)
                    .focused($focused)
                    .font(.system(size: 16, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 170)
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                    .onChange(of: typed) { old, new in
                        // Typing adds a character or two at a time; a paste adds a lot at once.
                        if new.count - old.count > 3 {
                            typed = old
                            pasteWarning = true
                        }
                    }

                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = ctx.date.timeIntervalSince(issuedAt)
                    let words = Passage.normalize(typed).split(separator: " ").count
                    HStack {
                        Text("\(words)/\(Config.passageWords) words")
                        Spacer()
                        Text(secs < Config.emergencyTyping ? "at least \(Int(Config.emergencyTyping - secs))s more" : "\(Int(secs))s")
                    }
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.faint)
                }

                if let err = model.emergencyError {
                    Text(err).font(.footnote).foregroundStyle(Theme.alarm)
                }
                if pasteWarning {
                    Text("Pasting is off. Type it by hand.")
                        .font(.footnote).foregroundStyle(Theme.alarm)
                }

                PrimaryButton(title: "Submit", enabled: !typed.isEmpty) { model.emergencySubmit(typed) }
            }
            .padding(20)
        }
    }

    private var accepted: some View {
        VStack(spacing: 18) {
            Image(systemName: "hourglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.brassFill)
            Text("Accepted").font(Theme.display(28, .bold))
            Text("The 20-minute wait has started. Everything stays locked until it ends, and you can still change your mind.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.soft)
            PrimaryButton(title: "Done") { dismiss() }
                .padding(.top, 10)
        }
        .padding(28)
    }
}
