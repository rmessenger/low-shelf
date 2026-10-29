import SwiftUI
import TuningCore

@available(macOS 14.2, *)
struct TuningView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var manage = false
    @State private var history = false
    @State private var deletion = false
    private let accent = Color(red: 0.65, green: 0.91, blue: 0.62)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Picker("Headphones", selection: Binding(get: { model.library.selected }, set: { model.selectProfile($0) })) {
                        Text("Choose headphones").tag(Optional<UUID>.none)
                        ForEach(model.library.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                    }
                    Button { manage = true } label: { Image(systemName: "gearshape") }.help("Manage headphones")
                        .accessibilityLabel("Manage headphones")
                }
                if let profile = model.library.profile {
                    ProfileCurve(curve: model.currentCurve, accent: accent).frame(height: 190)
                    HStack {
                        Text("Current curve").font(.headline)
                        Spacer()
                        Button("History (\(profile.session?.completedComparisons ?? 0))") { history = true }
                            .disabled((profile.session?.completedComparisons ?? 0) == 0)
                    }
                    HStack(spacing: 8) {
                        auditionButton(.a); auditionButton(.current); auditionButton(.b)
                    }.controlSize(.large)
                    VStack(spacing: 12) {
                        Text("Which sounds better?").font(.headline)
                        HStack(spacing: 6) {
                            ForEach(PreferenceRating.allCases, id: \.self) { rating in
                                Button { model.vote(rating) } label: {
                                    Text(rating.buttonLabel)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                }
                                .buttonStyle(.bordered).disabled(!model.canVote)
                                .accessibilityLabel(rating.label)
                            }
                        }
                        Text(model.running ? (model.canVote ? "Each vote updates Current and saves automatically." : "Listen to both A and B to unlock voting.") : "Enable EQ to compare A and B.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                } else {
                    Text("Add your headphones to start finding the sound you prefer.").foregroundStyle(.secondary)
                    Button("Add headphones") { manage = true }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                }
                Divider()
                HStack {
                    Button(model.running ? "Disable EQ" : "Enable EQ") { model.toggle() }
                    Text(model.running ? "ENABLED" : "DISABLED").font(.caption.monospaced()).foregroundStyle(model.running ? accent : .secondary)
                    Spacer()
                    Text(AppModel.shortcutLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("Output: \(model.outputName)").font(.caption).foregroundStyle(.secondary)
                Text(model.profileError ?? model.error ?? model.shortcutError ?? model.warning ?? "Your profiles and progress stay on this Mac.")
                    .font(.caption).foregroundStyle(model.profileError != nil || model.error != nil ? .orange : .secondary)
            }.padding(26)
        }
        .background(Color(red: 0.055, green: 0.073, blue: 0.069))
        .sheet(isPresented: $manage) { profileManager }
        .sheet(isPresented: $history) { VoteHistoryView(model: model) }

    }
    private var profileManager: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Manage headphones").font(.title2)
            TextField("Headphone name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Add headphones") { model.addProfile(name); name = ""; manage = false }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Rename selected") { model.renameProfile(name); name = ""; manage = false }
                    .disabled(model.library.profile == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Delete selected…", role: .destructive) { deletion = true }.disabled(model.library.profile == nil)
                Spacer()
                Button("Done") { manage = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 400)
        .confirmationDialog("Delete this headphone profile and its tuning history?", isPresented: $deletion) {
            Button("Delete profile", role: .destructive) { model.deleteProfile(); manage = false }
        }
    }
    private func auditionButton(_ choice: AppModel.Audition) -> some View {
        Button { model.listen(choice) } label: {
            Text("\(model.audition == choice ? "● " : "")\(choice.rawValue)").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).tint(model.audition == choice ? accent : .gray)
            .accessibilityLabel("Listen to \(choice.rawValue)")
            .accessibilityValue(model.audition == choice ? "Selected" : "")
    }
}

struct ProfileCurve: View {
    let curve: StereoEQCurve
    let accent: Color
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label("Left", systemImage: "line.diagonal").foregroundStyle(accent)
                Label("Right", systemImage: "line.diagonal").foregroundStyle(.cyan)
                Spacer()
            }.font(.caption2)
            Canvas { context, size in
                for db in [-12.0, 0, 12] {
                    let y = size.height * (0.5-db/32)
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3,4]))
                }
                for (channel, color, dash) in [(curve.left, accent, [CGFloat]()), (curve.right, Color.cyan, [CGFloat(5), 3])] {
                    var path = Path()
                    let values = channel.shape()
                    for i in values.indices {
                        let p = CGPoint(x: Double(i)/Double(values.count-1)*size.width, y: size.height*(0.5-values[i]/32))
                        if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
                }
            }.clipped()
            HStack { Text("20 Hz"); Spacer(); Text("Relative shape · ±16 dB"); Spacer(); Text("20 kHz") }
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Left and right headphone EQ response curves")
    }
}
