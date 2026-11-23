import FamilyControls
import SwiftUI

private let lengths: [TimeInterval] = [15, 30, 60, 120, 240, 480, 1440, 4320, 10080].map { $0 * 60 }

/// No lock running: pick apps and a length, then hold to lock.
struct IdleView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("length") private var length: Double = 3600
    @State private var picking = false
    @State private var picked = FamilyActivitySelection()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                Dial(progress: length / Config.maxLock, glowing: false) {
                    VStack(spacing: 4) {
                        Text(Fmt.length(length))
                            .font(Theme.display(54, .bold))
                            .contentTransition(.numericText())
                        Text("ends \(Fmt.when(Date().addingTimeInterval(length)))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.soft)
                    }
                    .animation(.snappy, value: length)
                }
                .frame(maxWidth: 290)
                .padding(.vertical, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lengths, id: \.self) { l in
                            Chip(title: Fmt.length(l), selected: length == l) { length = l }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)

                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(text: "To lock")
                            Text(model.state.selection.summary)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        Button(model.state.selection.itemCount == 0 ? "Choose" : "Edit") { openPicker() }
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Theme.brass.opacity(0.15), in: Capsule())
                    }
                    if model.state.selection.itemCount > 0 {
                        TokenIcons(selection: model.state.selection)
                    } else {
                        Button(action: openPicker) {
                            HStack {
                                Image(systemName: "plus.app")
                                Text("Pick apps, categories, or websites")
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.soft)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5])).foregroundStyle(Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HoldButton(title: "Hold to lock for \(Fmt.length(length))", enabled: model.state.selection.itemCount > 0) {
                    model.startLock(for: length)
                }

                Text("Until the timer ends, locked apps won't open, apps can't be deleted, and the clock stays automatic.")
                    .font(.footnote)
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .familyActivityPicker(isPresented: $picking, selection: $picked)
        .onChange(of: picking) { _, open in if !open { model.pick(picked) } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time").font(Theme.display(34, .bold))
                Text("Ready when you are.").font(.system(size: 15)).foregroundStyle(Theme.soft)
            }
            Spacer()
            Image(systemName: "lock.open.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.soft)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.07), in: Circle())
        }
    }

    private func openPicker() {
        picked = model.pickerStart
        picking = true
    }
}
