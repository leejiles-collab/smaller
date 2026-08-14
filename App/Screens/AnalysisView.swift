import SwiftUI
import SmallerKit

/// What we found, then the choice.
struct AnalysisView: View {
    let file: ImportedFile
    let inventory: PDFInventory
    @Binding var intent: Intent
    @Binding var targetMegabytes: Double
    let onStart: () -> Void
    let onClose: () -> Void

    @FocusState private var targetFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                header

                VStack(spacing: Metrics.cardSpacing) {
                    if showsLosslessCard {
                        IntentCard(
                            title: "Keep every pixel",
                            detail: "Remove duplicated content — no quality loss at all",
                            isSelected: intent == .profile(.lossless),
                            isFeatured: true
                        ) {
                            select(.profile(.lossless))
                        }
                    }

                    ForEach(CompressionProfile.presets) { profile in
                        IntentCard(
                            title: profile.userLabel,
                            detail: profile.userDescription,
                            isSelected: intent == .profile(profile)
                        ) {
                            select(.profile(profile))
                        }
                    }
                }

                targetSection

                Button(action: onStart) {
                    Text("Make it smaller")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, Metrics.stackSpacing)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", action: onClose)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.displayName)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(ByteFormat.string(inventory.byteSize)) · \(pagesText)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(file.displayName), \(SpokenBytes.string(inventory.byteSize)), \(pagesText)"
        )
    }

    private var pagesText: String {
        inventory.pageCount == 1 ? "1 page" : "\(inventory.pageCount) pages"
    }

    /// Only offered when de-duplication alone is a real win.
    ///
    /// On the RL deck 20.1 of 25.7 MB saved came from storing repeated images
    /// once: 75% smaller with the file pixel-for-pixel identical, which beats
    /// anything a recoding profile can offer. On the RSA deck the same pass only
    /// reaches 31%, so the card correctly stays hidden there.
    private var showsLosslessCard: Bool {
        inventory.isWorthDeduplicating
    }

    // MARK: - Size target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Button {
                select(.target(bytes: Int(targetMegabytes * 1_000_000)))
                targetFieldFocused = true
            } label: {
                HStack {
                    Image(systemName: intent.isTarget ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(intent.isTarget ? Color.accentColor : Color.secondary.opacity(0.5))
                        .accessibilityHidden(true)
                    Text("Need it under a limit?")
                        .font(.cardTitle)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(intent.isTarget ? [.isButton, .isSelected] : .isButton)

            if intent.isTarget {
                HStack(spacing: 10) {
                    TextField("5", value: $targetMegabytes, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .focused($targetFieldFocused)
                        .onChange(of: targetMegabytes) { _, newValue in
                            let clamped = min(max(newValue, 0.1), 500)
                            intent = .target(bytes: Int(clamped * 1_000_000))
                        }
                        .accessibilityLabel("Size limit in megabytes")
                    Text("MB")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(
                    intent.isTarget ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: intent.isTarget ? 2 : 1
                )
        )
    }

    /// One choice, not two: selecting anything deselects everything else.
    private func select(_ new: Intent) {
        withAnimation(.easeInOut(duration: 0.15)) {
            intent = new
        }
        if !new.isTarget { targetFieldFocused = false }
    }
}

/// Nothing to gain, said plainly, with no picker to argue with.
struct NothingToGainView: View {
    let file: ImportedFile
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Metrics.stackSpacing) {
            Spacer()
            Text(message)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(file.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(Metrics.screenPadding)
        .frame(maxWidth: 520)
    }
}
