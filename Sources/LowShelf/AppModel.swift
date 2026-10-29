import AppKit
import BassDSP
import Combine
import Carbon
import HotKeySupport
import CoreAudio
import TuningCore

@available(macOS 14.2, *)
@MainActor
final class AppModel: ObservableObject {
    static let shortcutLabel = "⌃⌥⌘B"
    @Published var boost: Double { didSet { update() } }
    @Published var frequency: Double { didSet { update() } }
    @Published var steepness: Double { didSet { update() } }
    @Published var trim: Double { didSet { update() } }
    @Published private(set) var running = false
    @Published private(set) var outputName = "System output"
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var peak: Float = 0
    @Published private(set) var warning: String?
    @Published private(set) var error: String?
    @Published private(set) var shortcutError: String?
    private var globalShortcut: GlobalHotKey?
    @Published var headphonesMode = false {
        didSet {
            UserDefaults.standard.set(headphonesMode, forKey: "headphonesMode")
            audition = .saved; heard = []; tuningActive = false
            guard !headphonesMode || library.profile != nil else { stop(); return }
            applyProfile()
        }
    }
    @Published private(set) var library = ProfileLibrary()
    @Published private(set) var profileError: String?
    @Published private(set) var audition: Audition = .saved
    @Published private(set) var tuningActive = false
    @Published private(set) var heard: Set<Audition> = []
    private var profilesReadOnly = false
    private let profileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent((Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "LowShelf") + "/profiles.json")
    private let engine = AudioEngine()
    private var timer: Timer?
    private var routeTicks = 0
    private var previousCallbacks: UInt64 = 0
    private var staleTicks = 0
    private var clipTicks = 0

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["boost": 4.0, "frequency": 100.0, "steepness": 1.0, "trim": 0.0])
        boost = min(24, max(0, defaults.double(forKey: "boost")))
        frequency = min(500, max(20, defaults.double(forKey: "frequency")))
        steepness = min(1, max(0.1, defaults.double(forKey: "steepness")))
        trim = min(0, max(-18, defaults.double(forKey: "trim")))
        do { library = try ProfileStorage.load(from: profileURL) }
        catch { profileError = error.localizedDescription; profilesReadOnly = true }
        headphonesMode = defaults.bool(forKey: "headphonesMode")
        refreshOutput()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.globalShortcut = nil
                    self?.stop()
                }
            }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.stop()
                    self.warning = "Disabled for sleep. Enable bass boost when you return."
                }
            }
        do {
            globalShortcut = try GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey | cmdKey)
            ) { [weak self] in self?.toggle() }
        } catch {
            shortcutError = error.localizedDescription
        }
    }

    func toggle() {
        running ? stop() : start()
    }

    private func update() {
        UserDefaults.standard.set(boost, forKey: "boost")
        UserDefaults.standard.set(frequency, forKey: "frequency")
        UserDefaults.standard.set(steepness, forKey: "steepness")
        UserDefaults.standard.set(trim, forKey: "trim")
        if let dsp = engine.dsp { bass_configure(dsp, boost, frequency, steepness, trim) }
    }

    func start() {
        error = nil
        warning = nil
        guard !headphonesMode || library.profile != nil else { error = "Create or select a headphone profile first."; return }
        do {
            try engine.start(boost: boost, frequency: frequency, steepness: steepness, trim: trim,
                             curve: headphonesMode ? auditionCurve : nil, gain: headphonesMode ? auditionGain : nil)
            running = true
            heard = [audition]
            previousCallbacks = 0
            staleTicks = 0
            refreshOutput()
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        if let failure = engine.stop() { error = failure }
        running = false
        heard = []
        peak = 0
        warning = nil
    }

    func preset(boost: Double, frequency: Double) {
        self.boost = boost
        self.frequency = frequency
        steepness = 1
    }

    private func refreshOutput() {
        do {
            let output = try AudioEngine.defaultOutput()
            outputName = output.name
            sampleRate = output.rate
        } catch { self.error = error.localizedDescription }
    }

    private func poll() {
        if let dsp = engine.dsp, running {
            peak = max(bass_take_peak(dsp), peak * 0.72)
            if peak >= 0.99 { clipTicks = 30 }
            if clipTicks > 0 {
                warning = "Near full scale. Reduce Output trim if you hear distortion."
                clipTicks -= 1
            } else { warning = nil }
            if bass_take_faults(dsp) != 0 {
                stop()
                error = "Audio format changed or an invalid sample was received. Original playback has been restored."
                return
            }
            let callbacks = bass_callbacks(dsp)
            staleTicks = callbacks == previousCallbacks ? staleTicks + 1 : 0
            previousCallbacks = callbacks
            if staleTicks > 50 {
                stop()
                error = "The audio route stopped responding. Check audio capture permission, then try enabling bass boost again."
                return
            }
        }
        routeTicks += 1
        guard routeTicks >= 10 else { return }
        routeTicks = 0
        do {
            let current = try AudioEngine.defaultOutput()
            if running, let previous = engine.output,
               current.id != previous.id || abs(current.rate - previous.rate) > 1 {
                stop()
                warning = "Output changed. Enable bass boost to use \(current.name)."
            }
            outputName = current.name
            sampleRate = current.rate
        } catch {
            if running { stop() }
            self.error = error.localizedDescription
        }
    }
}

@available(macOS 14.2, *)
extension AppModel {
    enum Audition: String, CaseIterable, Hashable { case saved = "Saved", a = "A", b = "B", best = "Suggested" }
    var canVote: Bool { tuningActive && running && heard.contains(.a) && heard.contains(.b) && (audition == .a || audition == .b) }
    var auditionCurve: StereoEQCurve {
        guard let profile = library.profile else { return StereoEQCurve() }
        switch audition {
        case .saved: return profile.saved
        case .a: return profile.session?.current?.a ?? profile.saved
        case .b: return profile.session?.current?.b ?? profile.saved
        case .best: return profile.session?.recommendation ?? profile.saved
        }
    }
    var auditionGain: StereoGain {
        let rate = sampleRate > 0 ? sampleRate : 48000
        guard let profile = library.profile, let session = profile.session, let pair = session.current else {
            return auditionCurve.playbackGain(rate: rate)
        }
        return auditionCurve.playbackGain(rate: rate, alongside: [profile.saved, session.recommendation, pair.a, pair.b])
    }
    private func saveProfiles() {
        guard !profilesReadOnly else { return }
        do { try ProfileStorage.save(library, to: profileURL); profileError = nil }
        catch { profileError = error.localizedDescription }
    }
    private func applyProfile() {
        engine.apply(curve: headphonesMode ? auditionCurve : nil, gain: headphonesMode ? auditionGain : nil)
    }
    func selectProfile(_ id: UUID?) {
        library.selected = id; audition = .saved; heard = []; tuningActive = false; saveProfiles(); applyProfile()
    }
    func addProfile(_ name: String) {
        guard !profilesReadOnly else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        library.add(name: cleaned); audition = .saved; heard = []; tuningActive = false; saveProfiles(); applyProfile()
    }
    func renameProfile(_ name: String) {
        guard let index = library.index, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveProfiles()
    }
    func deleteProfile() {
        guard let index = library.index else { return }
        stop(); library.profiles.remove(at: index); library.selected = library.profiles.first?.id
        audition = .saved; tuningActive = false; saveProfiles()
    }
    func beginTuning() {
        guard let index = library.index else { return }
        tuningActive = true
        if library.profiles[index].session == nil {
            library.profiles[index].session = StereoPreferenceSearch(initial: library.profiles[index].saved,
                seed: UInt64.random(in: 1...UInt64.max))
        }
        if library.profiles[index].session?.current == nil { _ = library.profiles[index].session?.next() }
        audition = .a; heard = running ? [.a] : []; saveProfiles(); applyProfile()
    }
    func pauseTuning() { tuningActive = false; heard = []; listen(.saved) }
    func listen(_ choice: Audition) { audition = choice; if running { heard.insert(choice) }; applyProfile() }
    func vote(_ choice: PreferenceRating) {
        guard canVote, let index = library.index else { return }
        library.profiles[index].session?.answer(choice)
        _ = library.profiles[index].session?.next()
        audition = .a; heard = running ? [.a] : []; saveProfiles(); applyProfile()
    }
    func undoVote() {
        guard let index = library.index else { return }
        library.profiles[index].session?.undo()
        audition = .a; heard = running ? [.a] : []; saveProfiles(); applyProfile()
    }
    func saveRecommendation() {
        guard let index = library.index, let session = library.profiles[index].session else { return }
        library.profiles[index].saved = session.recommendation
        audition = .saved; tuningActive = false; saveProfiles(); applyProfile()
    }
    func resetTuning() {
        guard let index = library.index else { return }
        library.profiles[index].session = nil
        audition = .saved; tuningActive = false; saveProfiles(); applyProfile()
    }
}
