import SwiftUI
import SmallerKit

/// The compact sheet.
///
/// Deliberately not the app's analysis screen. This appears over whatever the
/// user was already doing, in a sheet they did not navigate to, so it says what
/// the file is, offers the choice, and gets out of the way.
struct ShareFlowView: View {
    @State private var model = ShareModel()
    @State private var isExporting = false

    let providers: [NSItemProvider]
    /// What went wrong the last time this sheet was opened, if it did not
    /// survive long enough to say so itself.
    let lastRunReport: String?
    /// Told once, the first time this actually gets on screen. What stands
    /// behind it is a fallback that assumes it never will.
    let onDraw: () -> Void
    let onShare: (URL) -> Void
    let onCancel: () -> Void
    let onOpenApp: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let lastRunReport {
                Text(lastRunReport)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.08))
            }

            Group {
                switch model.phase {
                case .loading:
                    centred { ProgressView().controlSize(.large) }

                case .ready(let item, let inventory):
                    choices(item: item, inventory: inventory)

                case .working(let fraction):
                    centred {
                        VStack(spacing: 14) {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 240)
                            Text("Making it smaller…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .finished(let delivered):
                    finished(delivered)

                case .handOff(let item, let message):
                    handOff(item: item, message: message)

                case .paywall(let item, _):
                    SharePaywallView(
                        purchases: model.purchases,
                        onPurchased: { model.markPurchased() },
                        onOpenApp: { openApp(item) }
                    )

                case .failed(let failure):
                    centred {
                        VStack(spacing: 10) {
                            Text(failure.message)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if let detail = failure.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Close", action: onCancel)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { onDraw() }
        .task { model.load(from: providers) }
        .onDisappear { model.tearDown() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button("Cancel") {
                model.cancel()
                onCancel()
            }
            Spacer()
            Text("Smaller")
                .font(.headline)
            Spacer()
            // Balances the cancel button so the title sits centred.
            Button("Cancel") {}.opacity(0).disabled(true).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
    }

    private func choices(item: ShareModel.ImportedItem, inventory: PDFInventory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text("\(ByteFormat.string(inventory.byteSize)) · \(pages(inventory))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                VStack(spacing: 8) {
                    if inventory.isWorthDeduplicating {
                        ShareOption(
                            title: "Keep every pixel",
                            detail: "No quality loss at all",
                            isSelected: model.intent == .profile(.lossless)
                        ) { model.intent = .profile(.lossless) }
                    }
                    ForEach(CompressionProfile.presets) { profile in
                        ShareOption(
                            title: profile.userLabel,
                            detail: profile.userDescription,
                            isSelected: model.intent == .profile(profile)
                        ) { model.intent = .profile(profile) }
                    }
                }

                Button {
                    model.start()
                } label: {
                    Text("Compress")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
        }
    }

    private func finished(_ delivered: ShareModel.Delivered) -> some View {
        let result = delivered.result
        return ScrollView {
            VStack(spacing: 8) {
                Text(ByteFormat.string(result.originalBytes))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .strikethrough(true, color: .secondary)
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(ByteFormat.string(result.finalBytes))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text("\(result.reductionPercent)% smaller")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(SpokenShareBytes.string(result.originalBytes)) reduced to "
                        + "\(SpokenShareBytes.string(result.finalBytes)), "
                        + "\(result.reductionPercent) percent smaller"
                    )

                savedNote(delivered.saved)
                    .padding(.top, 10)

                // The same two actions, in the same order, with the same words
                // as the app's Done screen. Coming in through the share sheet
                // rather than the app should not change what the buttons are
                // called or what they do.
                //
                // "Attach it" used to sit here, and it handed the file back to
                // the host with completeRequest. That is an Action-extension
                // pattern: a Share extension is terminal, most hosts discard
                // returned items, and Mail is one of them — which is how a
                // compressed file could vanish after the button that promised
                // to attach it was tapped.
                //
                // Both are optional. The file already exists either way, which
                // is the entire point of the note above them.
                VStack(spacing: 8) {
                    Button {
                        onShare(delivered.attachment)
                    } label: {
                        Text("Share")
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Save elsewhere") { isExporting = true }
                        .font(.callout)
                        .padding(.top, 2)
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .fileExporter(
                isPresented: $isExporting,
                document: ExportedPDF(url: delivered.attachment),
                contentType: .pdf,
                // Already "<original>-smaller.pdf". Running it through
                // outputName again would make it "-smaller-smaller".
                defaultFilename: (delivered.attachment.lastPathComponent as NSString)
                    .deletingPathExtension
            ) { _ in }
        }
    }

    /// Where the copy went. Deliberately above the buttons: it is the thing
    /// that is already true, and the buttons are what is optional.
    @ViewBuilder
    private func savedNote(_ saved: ShareModel.SavedState) -> some View {
        switch saved {
        case .saved:
            VStack(spacing: 3) {
                Label("Saved to Smaller", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                // Said plainly rather than claiming it is in Files already: a
                // share extension cannot write to the app's Files folder, so
                // the app files it the next time it runs.
                Text("In \(FilesLibrary.userFacingLocation) next time you open the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

        case .failed(let reason):
            VStack(spacing: 3) {
                Label("Couldn't keep a copy", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func handOff(item: ShareModel.ImportedItem, message: String) -> some View {
        centred {
            VStack(spacing: 12) {
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(item.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Open in Smaller") { openApp(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
        }
    }

    private func openApp(_ item: ShareModel.ImportedItem) {
        guard let url = model.handOffURL(for: item) else { return }
        onOpenApp(url)
    }

    private func pages(_ inventory: PDFInventory) -> String {
        inventory.pageCount == 1 ? "1 page" : "\(inventory.pageCount) pages"
    }
}

/// A row in the sheet. Same idea as the app's card, sized for a sheet.
private struct ShareOption: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Byte counts as VoiceOver should say them.
enum SpokenShareBytes {
    static func string(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f megabytes", mb) }
        return String(format: "%.0f kilobytes", Double(bytes) / 1_000)
    }
}
