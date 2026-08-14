import SwiftUI
import UniformTypeIdentifiers

/// Wordmark, one line, one button.
///
/// No recents, no history, no library. The moment this screen shows a list of
/// files we stop being a utility and start being a document manager, which is a
/// different app with a different job.
struct HomeView: View {
    let onPick: (URL) -> Void
    let onPickFailed: () -> Void

    @State private var isImporting = false

    var body: some View {
        VStack(spacing: Metrics.stackSpacing) {
            Spacer()

            VStack(spacing: 8) {
                Text("Smaller")
                    .font(.wordmark)
                Text("Make your PDF smaller.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)

            Spacer()

            VStack(spacing: 14) {
                Button {
                    isImporting = true
                } label: {
                    Text("Select PDF")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("or share a PDF to Smaller")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
                .frame(height: 40)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .frame(maxWidth: 520)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                onPick(url)
            case .failure:
                onPickFailed()
            }
        }
    }
}
