import SwiftUI
import TuningCore

@available(macOS 14.2, *)
struct TuningView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var manage = false
    @State private var reveal = false
    @State private var deletion = false
    @State private var restart = false
    private let accent = Color(red: 0.65, green: 0.91, blue: 0.62)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Find your sound").font(.system(size: 27, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(model.running ? "ENABLED" : "DISABLED").font(.caption.monospaced()).foregroundStyle(model.running ? accent : .secondary)
                }
                HStack {
                    Picker("Headphones", selection: Binding(get: { model.library.selected }, set: { model.selectProfile($0) })) {
                        Text("Choose headphones").tag(Optional<UUID>.none)
                        ForEach(model.library.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                    }
                    Button { manage = true } label: { Image(systemName: "gearshape") }.help("Manage headphones")
                        .accessibilityLabel("Manage headphones")
                }
                if let profile = model.library.profile {
                    if model.tuningActive, let session = profile.session, session.current != nil {
                        HStack {
                            Text("Comparison \(session.completedComparisons + 1)").font(.headline)
                            Spacer()
                            Button("Pause") { model.pauseTuning() }.font(.callout)
                        }
                        Text("Listen to the same passage with A and B. Which sounds better?")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) { auditionButton(.a); auditionButton(.b) }.controlSize(.large)
                        VStack(spacing: 8) {
                            ForEach(PreferenceRating.allCases, id: \.self) { rating in
                                Button { model.vote(rating) } label: {
                                    Text(rating.label).frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered).disabled(!model.canVote)
                            }
                        }
                        Text(model.running ? (model.canVote ? "There’s no wrong answer. Each choice helps refine both ears." : "Listen to both A and B before choosing.") : "Enable EQ below to listen and choose.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Undo") { model.undoVote() }.disabled(session.answers.isEmpty)
                            Spacer()
                            Button("Use this tuning") { model.saveRecommendation() }
                                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        }
                    } else {
                        ProfileCurve(curve: profile.saved, accent: accent).frame(height: 180)
                        Text("Tune the sound to your headphones and each ear, one simple comparison at a time.")
                            .foregroundStyle(.secondary)
                        Button(profile.session == nil ? "Start tuning" : "Continue tuning") { model.beginTuning() }
                            .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).controlSize(.large)
                    }
                    DisclosureGroup("Curve & session", isExpanded: $reveal) {
                        VStack(alignment: .leading, spacing: 12) {
                            ProfileCurve(curve: model.auditionCurve, accent: accent).frame(height: 130)
                            HStack { auditionButton(.saved); auditionButton(.best) }
                            Text("Keep playback volume steady. Level balancing is approximate. Progress saves automatically; Use this tuning applies the suggestion.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Restart tuning…") { restart = true }.disabled(profile.session == nil)
                        }.padding(.top, 12)
                    }.font(.callout)
                } else {
                    Text("Add your headphones to start finding the sound you prefer.").foregroundStyle(.secondary)
                    Button("Add headphones") { manage = true }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                }
                Divider()
                HStack {
                    Button(model.running ? "Disable EQ" : "Enable EQ") { model.toggle() }
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
        .confirmationDialog("Restart tuning? Your saved curves will be kept, but comparison history will be removed.", isPresented: $restart) {
            Button("Restart tuning", role: .destructive) { model.resetTuning(); model.beginTuning() }
        }
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
