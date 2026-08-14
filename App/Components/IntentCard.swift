import SwiftUI

/// One choice on the analysis screen: a label, a line explaining it, and no
/// numbers.
///
/// Deliberately no size estimate. Prediction currently runs at 55% mean error
/// against measured output, and a number that wrong is worse than no number —
/// it would be the only thing on the card anyone read.
struct IntentCard: View {
    let title: String
    let detail: String
    let isSelected: Bool
    /// The lossless card, which is a different kind of offer and looks like it.
    var isFeatured: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.cardSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.cardTitle)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.cardDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .fill(isFeatured
                  ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.08)
                  : Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.06))
    }
}
