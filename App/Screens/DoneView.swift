import SwiftUI
import SmallerKit
import UniformTypeIdentifiers

/// The result: two numbers and the difference between them.
struct DoneView: View {
    let finished: Finished
    let exportURL: URL
    let onRename: (String) -> Void
    let onCompressAnother: () -> Void

    @State private var countedBytes: Int
    @State private var isExporting = false
    @State private var isRenaming = false
    @State private var draftName: String

    init(
        finished: Finished,
        exportURL: URL,
        onRename: @escaping (String) -> Void,
        onCompressAnother: @escaping () -> Void
    ) {
        self.finished = finished
        self.exportURL = exportURL
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
        .sensoryFeedback(.success, trigger: finished.result.finalBytes)
        .task {
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
            document: PDFFile(url: exportURL),
            contentType: .pdf,
            defaultFilename: (finished.exportName as NSString).deletingPathExtension
        ) { _ in }
    }

    // MARK: - The numbers

    private var numbers: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(ByteFormat.string(result.originalBytes))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .strikethrough(true, color: .secondary)
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

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
                Text("Save to Files")
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

/// Wrapper so `fileExporter` can hand over a file we already wrote, without
/// reading it into memory first.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
