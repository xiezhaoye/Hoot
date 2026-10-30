import AppKit
import SwiftUI

struct InspectorWell<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(.horizontal, 8).frame(minHeight: 32)
            .background(EditorStyle.well, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(EditorStyle.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.025), radius: 1, y: 1)
    }
}

struct InspectorSwitch: View {
    @Binding var isOn: Bool
    let label: String
    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule().fill(isOn ? EditorStyle.accent : Color.secondary.opacity(0.23))
                .frame(width: 27, height: 15)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(1)
                        .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                }
        }.buttonStyle(.plain).accessibilityLabel(label)
            .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
    }
}

/// Native keyboard/accessibility semantics, with the exact track and thumb from the design.
struct InspectorSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let label: String
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = BlueSliderCell()
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        if slider.doubleValue != value { slider.doubleValue = value }
    }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
    }
    @MainActor final class BlueSliderCell: NSSliderCell {
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let knob = knobRect(flipped: flipped)
            let bar = NSRect(x: rect.minX + knob.width / 2, y: rect.midY - 2, width: max(1, rect.width - knob.width), height: 4)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            let fill = NSRect(x: bar.minX, y: bar.minY, width: max(0, min(bar.width, knob.midX - bar.minX)), height: bar.height)
            EditorStyle.nsAccent.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }
        override func drawKnob(_ rect: NSRect) {
            EditorStyle.nsAccent.setFill()
            let size: CGFloat = 15
            NSBezierPath(ovalIn: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)).fill()
        }
    }
}
