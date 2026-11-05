import AppKit
import BassDSP
import ServiceManagement
import SwiftUI

@available(macOS 14.2, *)
@main
struct LowShelfApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("LowShelf", id: "main") {
            ContentView(model: model)
                .frame(width: 510, height: 730)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Audio") {
                Button(model.running ? "Disable bass boost" : "Enable bass boost") {
                    model.toggle()
                }.keyboardShortcut("e", modifiers: .command)
                Divider()
                AutomationSettingsMenu(model: model)
            }
        }
        MenuBarExtra {
            LowShelfMenu(model: model)
        } label: {
            Image(systemName: model.running ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel(model.running ? "LowShelf — bass boost enabled" : "LowShelf — bass boost disabled")
                .help(model.running ? "LowShelf — bass boost enabled" : "LowShelf — bass boost disabled")
        }
    }
}

@available(macOS 14.2, *)
struct LowShelfMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("LowShelf · \(model.outputName)")
            Text(model.shortcutError == nil ? "Toggle globally: \(AppModel.shortcutLabel)" : "Global shortcut unavailable")
            Button(model.running ? "Disable bass boost" : "Enable bass boost") {
                model.toggle()
            }
            Divider()
            AutomationSettingsMenu(model: model)
            Divider()
            Button("Show LowShelf") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit LowShelf") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .onAppear { model.refreshLoginItem() }
    }
}

@available(macOS 14.2, *)
struct AutomationSettingsMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.loginNeedsApproval {
                Button("Approve Launch at Login…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if let error = model.loginError {
                Text(error)
            }
            Toggle("Automatic Bass Boost for Headphones", isOn: $model.automaticHeadphones)
                .help("Enable bass boost when headphones become the output; disable it when switching away.")
        }
        .onAppear { model.refreshLoginItem() }
    }
}

@available(macOS 14.2, *)
struct ContentView: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.65, green: 0.91, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LowShelf").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("A little more depth.").foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.running ? accent : .gray).frame(width: 6, height: 6)
                    Text(model.running ? "ENABLED" : "DISABLED")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }.padding(9).background(.white.opacity(0.05), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BASS SHAPE").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text("Relative to mids & highs").font(.system(size: 10))
                }.foregroundStyle(.secondary)
                ResponseCurve(boost: model.boost, frequency: model.frequency,
                              steepness: model.steepness, sampleRate: model.sampleRate, accent: accent)
                    .frame(height: 115)
                    .accessibilityLabel("Bass response, \(model.boost, specifier: "%.1f") decibels at \(model.frequency, specifier: "%.0f") hertz")
                GeometryReader { geometry in
                    ForEach([20.0, 100, 1000, 20000], id: \.self) { hz in
                        Text(hz == 20 ? "20 Hz" : (hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"))
                            .position(x: max(14, min(geometry.size.width - 12,
                                log10(hz / 20) / 3 * geometry.size.width)), y: 6)
                    }
                }.frame(height: 12).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            VStack(spacing: 17) {
                control("Bass boost", value: $model.boost, range: 0...24, unit: "dB", decimals: 1)
                control("Shelf midpoint", value: $model.frequency, range: 20...500, unit: "Hz", decimals: 0)
                control("Shelf steepness", value: Binding(
                    get: { model.steepness * 100 },
                    set: { model.steepness = $0 / 100 }
                ), range: 10...100, unit: "%", decimals: 0)
                .help("Lower values spread the transition across more frequencies. 100% is the steepest shelf without a resonant bump.")
                HStack(spacing: 8) {
                    preset("Subtle", boost: 3, frequency: 80)
                    preset("Warm", boost: 5, frequency: 120)
                    preset("Deep", boost: 8, frequency: 65)
                    Spacer()
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Automatic headroom", systemImage: "checkmark.shield")
                    Spacer()
                    Text(String(format: "−%.1f dB", model.boost + 1))
                        .monospacedDigit().foregroundStyle(accent)
                }.font(.system(size: 12))
                control("Output trim", value: $model.trim, range: -18...0, unit: "dB", decimals: 1)
                HStack(spacing: 10) {
                    Text("PEAK").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill(model.peak >= 0.99 ? Color.orange : accent)
                                .frame(width: geometry.size.width * meterPosition)
                        }
                    }.frame(height: 4)
                    Text(model.peak > 0.00001 ? String(format: "%.1f dBFS", 20 * log10(model.peak)) : "−∞ dBFS")
                        .font(.system(size: 10, design: .monospaced)).frame(width: 75, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                    Text(model.outputName).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f kHz", model.sampleRate / 1000)).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(model.running ? "Disable bass boost" : "Enable bass boost") {
                        model.toggle()
                    }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    .controlSize(.large)
                    .help("Toggle from any app with Control–Option–Command–B.")
                    Spacer()
                    Text(model.shortcutError == nil ? AppModel.shortcutLabel : "Shortcut unavailable")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityLabel(model.shortcutError == nil
                            ? "Global shortcut: Control Option Command B" : "Global shortcut unavailable")
                }
                Text(model.error ?? model.loginError ?? model.shortcutError ?? model.warning ?? (model.running
                    ? "Bass boost is enabled. Disabling restores normal playback and volume."
                    : "Bass boost is disabled. Enable it to apply your settings."))
                    .font(.system(size: 11)).foregroundStyle((model.error != nil || model.loginError != nil || model.shortcutError != nil) ? .orange : .secondary)
                    .lineLimit(3).frame(height: 42, alignment: .topLeading).textSelection(.enabled)
            }
        }
        .padding(28)
        .background(Color(red: 0.055, green: 0.073, blue: 0.069))
    }

    private var meterPosition: Double {
        min(1, max(0, (20 * log10(Double(max(model.peak, 0.000001))) + 60) / 60))
    }

    private func control(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, decimals: Int) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(String(format: "%.*f %@", decimals, value.wrappedValue, unit))
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(accent)
            }
            Slider(value: value, in: range)
                .tint(accent).accessibilityLabel(label)
        }
    }

    private func preset(_ name: String, boost: Double, frequency: Double) -> some View {
        Button(name) { model.preset(boost: boost, frequency: frequency) }
            .buttonStyle(.bordered).controlSize(.small)
    }
}

struct ResponseCurve: View {
    let boost: Double
    let frequency: Double
    let steepness: Double
    let sampleRate: Double
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let baseline = size.height - 8
            for db in [0.0, 12.0, 24.0] {
                let y = baseline - db / 24 * (size.height - 18)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            var curve = Path()
            for index in 0...300 {
                let x = Double(index) / 300
                let hz = 20 * pow(1000, x)
                let db = bass_response(max(44100, sampleRate), boost, frequency, steepness, hz)
                let point = CGPoint(x: x * size.width, y: baseline - db / 24 * (size.height - 18))
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: baseline))
            area.addLine(to: CGPoint(x: 0, y: baseline)); area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [accent.opacity(0.2), accent.opacity(0.01)]),
                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(curve, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}
