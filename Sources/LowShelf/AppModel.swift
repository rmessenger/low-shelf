import AppKit
import AutomationSupport
import ServiceManagement
import BassDSP
import Combine
import Carbon
import HotKeySupport
import CoreAudio

@available(macOS 14.2, *)
@MainActor
final class AppModel: ObservableObject {
    static let shortcutLabel = "⌃⌥⌘B"
    @Published var boost: Double { didSet { update() } }
    @Published var frequency: Double { didSet { update() } }
    @Published var steepness: Double { didSet { update() } }
    @Published var trim: Double { didSet { update() } }
    @Published var automaticHeadphones: Bool {
        didSet {
            UserDefaults.standard.set(automaticHeadphones, forKey: "automaticHeadphones")
            if automaticHeadphones {
                observedRoute = engine.output?.route
                refreshOutput()
            }
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var loginError: String?
    @Published private(set) var running = false
    @Published private(set) var outputName = "System output"
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var peak: Float = 0
    @Published private(set) var warning: String?
    @Published private(set) var error: String?
    @Published private(set) var shortcutError: String?
    private var globalShortcut: GlobalHotKey?
    private let engine = AudioEngine()
    private var timer: Timer?
    private var routeTicks = 0
    private var observedRoute: OutputRoute?
    private var sleeping = false
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
        automaticHeadphones = defaults.bool(forKey: "automaticHeadphones")
        refreshLoginItem()
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
                    guard let self else { return }
                    self.sleeping = true
                    guard self.running else { return }
                    self.stop()
                    self.warning = "Disabled for sleep."
                }
            }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sleeping = false
                    self.observedRoute = nil
                    self.refreshOutput()
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
        if running { stop() } else { start() }
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginNeedsApproval = status == .requiresApproval
        launchAtLogin = status == .enabled || loginNeedsApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        let result = Result { () throws(LoginItemFailure) in
            try LoginItem.setEnabled(enabled)
        }
        if case .failure(.registration(let message)) = result {
            loginError = "Launch at Login: \(message)"
        }
        refreshLoginItem()
    }

    private func update() {
        UserDefaults.standard.set(boost, forKey: "boost")
        UserDefaults.standard.set(frequency, forKey: "frequency")
        UserDefaults.standard.set(steepness, forKey: "steepness")
        UserDefaults.standard.set(trim, forKey: "trim")
        if let dsp = engine.dsp { bass_configure(dsp, boost, frequency, steepness, trim) }
    }

    func start() {
        guard !running, !sleeping else { return }
        error = nil
        warning = nil
        do {
            try engine.start(boost: boost, frequency: frequency, steepness: steepness, trim: trim)
            running = true
            previousCallbacks = 0
            staleTicks = 0
            if let output = engine.output {
                outputName = output.name
                sampleRate = output.rate
                observedRoute = output.route
            }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func stop() -> Bool {
        let failure = engine.stop()
        if let failure { error = failure }
        running = false
        peak = 0
        warning = nil
        return failure == nil
    }

    func preset(boost: Double, frequency: Double) {
        self.boost = boost
        self.frequency = frequency
        steepness = 1
    }

    private func refreshOutput() {
        guard !sleeping else { return }
        let result = Result { () throws(AudioFailure) in try AudioEngine.defaultOutput() }
        switch result {
        case .success(let current):
            let action = HeadphoneAutomation.action(enabled: automaticHeadphones,
                previous: observedRoute, current: current.route, running: running)
            observedRoute = current.route
            outputName = current.name
            sampleRate = current.rate
            switch action {
            case .start:
                start()
            case .restart:
                if stop() { start() }
            case .stop:
                stop()
            case .none:
                break
            }
        case .failure(let failure):
            if running { stop() }
            observedRoute = nil
            self.error = failure.localizedDescription
        }
    }

    private func poll() {
        guard !sleeping else { return }
        routeTicks += 1
        if routeTicks >= 5 {
            routeTicks = 0
            refreshLoginItem()
            refreshOutput()
        }
        if let dsp = engine.dsp, running {
            peak = max(bass_take_peak(dsp), peak * 0.72)
            if peak >= 0.99 { clipTicks = 30 }
            if clipTicks > 0 {
                warning = "Near full scale. Reduce Output trim if you hear distortion."
                clipTicks -= 1
            } else { warning = nil }
            if bass_take_faults(dsp) != 0 {
                let previousRoute = engine.output?.route
                refreshOutput()
                guard running, engine.output?.route == previousRoute else { return }
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
    }
}
