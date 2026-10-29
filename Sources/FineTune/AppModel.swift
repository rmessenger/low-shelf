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
    @Published private(set) var running = false
    @Published private(set) var outputName = "System output"
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var peak: Float = 0
    @Published private(set) var warning: String?
    @Published private(set) var error: String?
    @Published private(set) var shortcutError: String?
    private var globalShortcut: GlobalHotKey?
    @Published private(set) var library = ProfileLibrary()
    @Published private(set) var profileError: String?
    @Published private(set) var listening = ComparisonListening()
    private var profilesReadOnly = false
    // Keep profile storage independent of the app’s display name.
    private let profileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent((Bundle.main.object(forInfoDictionaryKey: "ProfileStorageDirectory") as? String ?? "LowShelf") + "/profiles.json")
    private let engine = AudioEngine()
    private var timer: Timer?
    private var routeTicks = 0
    private var previousCallbacks: UInt64 = 0
    private var staleTicks = 0
    private var clipTicks = 0

    init() {
        do { library = try ProfileStorage.load(from: profileURL) }
        catch { profileError = error.localizedDescription; profilesReadOnly = true }
        prepareSelectedProfile()
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
                    self.warning = "Disabled for sleep. Enable EQ when you return."
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

    func start() {
        error = nil
        warning = nil
        guard library.profile != nil else { error = "Create or select a headphone profile first."; return }
        do {
            try engine.start(curve: auditionCurve, gain: auditionGain)
            running = true
            listening.processingStarted()
            previousCallbacks = 0
            staleTicks = 0
            refreshOutput()
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        if let failure = engine.stop() { error = failure }
        running = false
        listening.processingStopped()
        peak = 0
        warning = nil
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
                warning = "Audio is near full scale. Disable EQ if you hear distortion."
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
                error = "The audio route stopped responding. Check audio capture permission, then try enabling EQ again."
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
                warning = "Output changed. Enable EQ to use \(current.name)."
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
    typealias Audition = ComparisonAudition
    var audition: Audition { listening.selection }
    var canVote: Bool { !profilesReadOnly && running && listening.canVote && library.profile?.session?.current != nil }
    var currentCurve: StereoEQCurve { library.profile?.currentCurve ?? StereoEQCurve() }
    var auditionCurve: StereoEQCurve {
        switch audition {
        case .current: return currentCurve
        case .a: return library.profile?.session?.current?.a ?? currentCurve
        case .b: return library.profile?.session?.current?.b ?? currentCurve
        }
    }
    var auditionGain: StereoGain {
        let rate = sampleRate > 0 ? sampleRate : 48000
        guard let pair = library.profile?.session?.current else { return auditionCurve.playbackGain(rate: rate) }
        return auditionCurve.playbackGain(rate: rate, alongside: [currentCurve, pair.a, pair.b])
    }
    @discardableResult
    private func commit(_ updated: ProfileLibrary) -> Bool {
        guard !profilesReadOnly else { return false }
        do {
            try ProfileStorage.save(updated, to: profileURL)
            library = updated; profileError = nil
            return true
        } catch {
            profileError = error.localizedDescription
            return false
        }
    }
    private func prepareSelectedProfile() {
        guard !profilesReadOnly, let index = library.index else { return }
        var updated = library
        if updated.profiles[index].prepareComparison() { commit(updated) }
    }
    private func applyProfile() {
        guard library.profile != nil else {
            if running { stop() }
            return
        }
        engine.apply(curve: auditionCurve, gain: auditionGain)
    }
    private func returnToCurrent() {
        listening.reset()
        applyProfile()
    }
    func selectProfile(_ id: UUID?) {
        var updated = library
        updated.selected = id
        if let index = updated.index { updated.profiles[index].prepareComparison() }
        if commit(updated) { returnToCurrent() }
    }
    func addProfile(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var updated = library
        updated.add(name: cleaned)
        if let index = updated.index { updated.profiles[index].prepareComparison() }
        if commit(updated) { returnToCurrent() }
    }
    func renameProfile(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = library.index, !cleaned.isEmpty else { return }
        var updated = library
        updated.profiles[index].name = cleaned
        commit(updated)
    }
    func deleteProfile() {
        guard let index = library.index else { return }
        var updated = library
        updated.profiles.remove(at: index); updated.selected = updated.profiles.first?.id
        if let next = updated.index { updated.profiles[next].prepareComparison() }
        if commit(updated) { stop(); returnToCurrent() }
    }
    func listen(_ choice: Audition) {
        listening.select(choice, processing: running)
        applyProfile()
    }
    func vote(_ choice: PreferenceRating) {
        guard canVote, let index = library.index else { return }
        var updated = library
        updated.profiles[index].record(choice)
        if commit(updated) { returnToCurrent() }
    }
    func rollbackVotes(to retainedCount: Int) {
        guard let index = library.index, let session = library.profiles[index].session,
              retainedCount >= 0, retainedCount < session.completedComparisons else { return }
        var updated = library
        updated.profiles[index].rollback(to: retainedCount)
        if commit(updated) { returnToCurrent() }
    }
}
