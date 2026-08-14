import SwiftUI

/// The progress ring, with the percentage inside it.
///
/// The ring is decorative — the percentage next to it is the same information
/// in text, so VoiceOver reads one value rather than announcing a circle.
struct ProgressRing: View {
    let fraction: Double

    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 180
    @ScaledMetric(relativeTo: .largeTitle) private var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)

            Text(percentText)
                .font(.bigNumber)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(percentText)
    }

    private var percentText: String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}
