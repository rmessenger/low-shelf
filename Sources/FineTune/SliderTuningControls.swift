import SwiftUI

@available(macOS 14.2, *)
struct SliderTuningControls: View {
    @ObservedObject var model: AppModel
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Current curve").font(.headline)
                Spacer()
                Text("Slider experiment").font(.caption).foregroundStyle(.secondary)
            }
            Text("Move between A and B to find the sound you prefer.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Slider(value: Binding(get: { model.sliderPosition }, set: { model.setSliderPosition($0) }), in: -1...1)
                    .tint(accent).accessibilityLabel("Sound preference")
                    .accessibilityValue(positionLabel)
                    .overlay(alignment: .center) {
                        Rectangle().fill(.secondary).frame(width: 1, height: 8).offset(y: 14).allowsHitTesting(false)
                    }
                HStack {
                    Button("A") { model.setSliderPosition(-1) }
                    Spacer()
                    Button("Current") { model.setSliderPosition(0) }
                    Spacer()
                    Button("B") { model.setSliderPosition(1) }
                }.buttonStyle(.plain).font(.callout)
            }
            HStack {
                Text(positionLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Use this sound") { model.acceptSlider() }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    .disabled(!model.canAcceptSlider)
            }
            Text(model.running ? "Your choice becomes Current. Keep the center to try a different adjustment." : "Enable EQ to listen and choose.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var positionLabel: String {
        if abs(model.sliderPosition) < 0.0005 { return "Current" }
        return "\(Int((abs(model.sliderPosition) * 100).rounded()))% toward \(model.sliderPosition < 0 ? "A" : "B")"
    }
}
