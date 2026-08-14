import SwiftUI
import SmallerKit
import UniformTypeIdentifiers

/// The result: two numbers and the difference between them.
struct DoneView: View {
    let finished: Finished
    let exportURL: URL
    let saved: CompressionStore.SavedState
    let onSave: () -> Void
    let onRename: (String) -> Void
    let onCompressAnother: () -> Void

    @State private var countedBytes: Int
    @State private var isExporting = false
    @State private var isRenaming = false
    @State private var draftName: String

    init(
        finished: Finished,
        exportURL: URL,
        saved: CompressionStore.SavedState,
        onSave: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onCompressAnother: @escaping () -> Void
    ) {
        self.finished = finished
        self.exportURL = exportURL
        self.saved = saved
        self.onSave = onSave
        self.onRename = onRename
        self.onCompressAnother = onCompressAnother
        // Starts at the original size and springs down to the final one. This
        // is the entire animation budget for the app.
        _countedBytes = State(initialValue: finished.result.originalBytes)
        _draftName = State(initialValue: finished.exportName)
    }

    private var result: CompressedResult { finished.result }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.stackSpacing) {
                if finished.metTarget {
                    numbers
                } else {
                    bestEffortNumbers
                }

                Text(finished.contextLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SavedNote(saved: saved)

                if !finished.surfacedWarnings.isEmpty {
                    VStack(spacing: Metrics.cardSpacing) {
                        ForEach(finished.surfacedWarnings) { warning in
                            WarningRow(warning: warning)
                        }
                    }
                    .padding(.top, 4)
                }

                actions
                    .padding(.top, 8)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, Metrics.stackSpacing)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Every screen has an exit in the same place. "Compress another"
                // at the bottom does the same thing, but it sits below the
                // actions and must not be the only way out.
                Button("Done", action: onCompressAnother)
            }
        }
        .sensoryFeedback(.success, trigger: finished.result.finalBytes)
        .task {
            // Before the numbers finish animating and well before the user
            // reaches for a button: the file is theirs whatever they do next.
            onSave()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                countedBytes = result.finalBytes
            }
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { draftName = finished.exportName }
            Button("Save") { onRename(draftName) }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: ExportedPDF(url: exportURL),
            contentType: .pdf,
            defaultFilename: (finished.exportName as NSString).deletingPathExtension
        ) { _ in }
    }

    // MARK: - The numbers

    private var numbers: some View {
        VStack(spacing: 6) {
            // Stacked, with the arrow pointing down between them. The drop from
            // 27.8 MB to 2.1 MB is the whole message, and a vertical fall reads
            // as a drop in a way that a sideways arrow into empty space does not.
            Text(ByteFormat.string(result.originalBytes))
                .font(.title3)
                .foregroundStyle(.secondary)
                .strikethrough(true, color: .secondary)

            Image(systemName: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.vertical, 2)

            Text(ByteFormat.string(countedBytes))
                .font(.hugeNumber)
                .monospacedDigit()
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text("\(result.reductionPercent)% smaller")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 6)
        }
        .padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenResult)
    }

    /// A target run that bottomed out. Still a real file, still offered — the
    /// headline just stops pretending it hit the number.
    private var bestEffortNumbers: some View {
        VStack(spacing: 10) {
            Text("Closest we could get")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(ByteFormat.string(countedBytes))
                .font(.hugeNumber)
                .monospacedDigit()
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if case .target(let bytes) = finished.intent {
                Text("You asked for \(ByteFormat.string(bytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("\(result.reductionPercent)% smaller")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Closest we could get. " + spokenResult)
    }

    /// "27.2 megabytes reduced to 1.6 megabytes, 94 percent smaller"
    private var spokenResult: String {
        "\(SpokenBytes.string(result.originalBytes)) reduced to "
        + "\(SpokenBytes.string(result.finalBytes)), "
        + "\(result.reductionPercent) percent smaller"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: Metrics.cardSpacing) {
            ShareLink(item: exportURL) {
                Text("Share")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                isExporting = true
            } label: {
                // Not "Save to Files" any more: it is already in Files. This is
                // for putting a second copy somewhere specific.
                Text("Save elsewhere")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                draftName = finished.exportName
                isRenaming = true
            } label: {
                Text(finished.exportName)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityLabel("Rename. Currently \(finished.exportName)")

            Button("Compress another", action: onCompressAnother)
                .font(.callout)
                .padding(.top, 4)
        }
    }
}

/// Warning rows, for the two things a person would actually act on.
private struct WarningRow: View {
    let warning: SurfacedWarning

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(warning.title)
                    .font(.subheadline.weight(.semibold))
                Text(warning.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }
}

/// Where the file went, stated plainly.
///
/// The whole point of writing it out before offering any buttons is that the
/// user can stop reading here and still have their file. So this says the
/// location, not "Done" — and if the write failed, it says that instead of
/// letting the user believe in a file that is not there.
struct SavedNote: View {
    let saved: CompressionStore.SavedState

    var body: some View {
        switch saved {
        case .pending:
            EmptyView()

        case .saved:
            Label("Saved to \(FilesLibrary.userFacingLocation)", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel("Saved to Files, in the Smaller folder")

        case .failed(let reason):
            VStack(spacing: 3) {
                Label("Couldn't save it to Files", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
