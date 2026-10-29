import AppKit
import SwiftUI

@available(macOS 14.2, *)
@main
struct FineTuneApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("FineTune", id: "main") {
            TuningView(model: model)
                .frame(width: 650, height: 720)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Audio") {
                Button(model.running ? "Disable EQ" : "Enable EQ") {
                    model.toggle()
                }.keyboardShortcut("e", modifiers: .command)
            }
        }
        MenuBarExtra {
            FineTuneMenu(model: model)
        } label: {
            Image(systemName: model.running ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel(model.running ? "FineTune — EQ enabled" : "FineTune — EQ disabled")
                .help(model.running ? "FineTune — EQ enabled" : "FineTune — EQ disabled")
        }
    }
}

@available(macOS 14.2, *)
struct FineTuneMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("FineTune · \(model.outputName)")
            Text(model.shortcutError == nil ? "Toggle globally: \(AppModel.shortcutLabel)" : "Global shortcut unavailable")
            Button(model.running ? "Disable EQ" : "Enable EQ") {
                model.toggle()
            }
            Divider()
            Button("Show FineTune") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit FineTune") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
