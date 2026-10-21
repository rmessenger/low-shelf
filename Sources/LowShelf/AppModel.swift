import AppKit
import BassDSP
import Combine
import CoreAudio

@available(macOS 14.2, *)
@MainActor
final class AppModel: ObservableObject {
    @Published var boost: Double { didSet { update() } }
    @Published var frequency: Double { didSet { update() } }
    @Published var trim: Double { didSet { update() } }
    @Published var bypass = false { didSet { update() } }
    @Published private(set) var running = false
    @Published private(set) var outputName = "System output"
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var peak: Float = 0
    @Published private(set) var warning: String?
    @Published private(set) var error: String?
    private let engine = AudioEngine()
    private var timer: Timer?
    private var routeTicks = 0
    private var previousCallbacks: UInt64 = 0
    private var staleTicks = 0
    private var clipTicks = 0

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["boost": 4.0, "frequency": 100.0, "trim": 0.0])
        boost = min(12, max(0, defaults.double(forKey: "boost")))
        frequency = min(250, max(40, defaults.double(forKey: "frequency")))
        trim = min(0, max(-18, defaults.double(forKey: "trim")))
        refreshOutput()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.stop()
                    self.warning = "Paused for sleep. Press Start when you return."
                }
            }
    }

    private func update() {
        UserDefaults.standard.set(boost, forKey: "boost")
        UserDefaults.standard.set(frequency, forKey: "frequency")
        UserDefaults.standard.set(trim, forKey: "trim")
        if let dsp = engine.dsp { bass_configure(dsp, boost, frequency, trim, bypass) }
    }

    func start() {
        error = nil
        warning = nil
        do {
            try engine.start(boost: boost, frequency: frequency, trim: trim, bypass: bypass)
            running = true
            previousCallbacks = 0
            staleTicks = 0
            refreshOutput()
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        if let failure = engine.stop() { error = failure }
        running = false
        peak = 0
        warning = nil
    }

    func preset(boost: Double, frequency: Double) {
        self.boost = boost
        self.frequency = frequency
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
                error = "The audio route stopped responding. Check audio capture permission, then try Start again."
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
                warning = "Output changed. Press Start to use \(current.name)."
            }
            outputName = current.name
            sampleRate = current.rate
        } catch {
            if running { stop() }
            self.error = error.localizedDescription
        }
    }
}
