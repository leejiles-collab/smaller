import SwiftUI
import SmallerKit

@main
struct SmallerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// One screen at a time, chosen by what the engine is doing.
struct RootView: View {
    @State private var store = CompressionStore()

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: phaseID)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .home:
            HomeView(
                onPick: { store.open(pickedURL: $0) },
                onPickFailed: { store.failedToPick() }
            )

        case .analyzing(let file):
            AnalyzingView(file: file, onCancel: { store.cancelAndReturnHome() })

        case .ready(let file, let inventory):
            AnalysisView(
                file: file,
                inventory: inventory,
                intent: Binding(get: { store.intent }, set: { store.intent = $0 }),
                targetMegabytes: Binding(
                    get: { store.targetMegabytes },
                    set: { store.targetMegabytes = $0 }
                ),
                onStart: { store.start() },
                onClose: { store.cancelAndReturnHome() }
            )

        case .working(let file, _, let progress):
            WorkingView(
                file: file,
                progress: progress,
                onCancel: { store.cancelWork() }
            )

        case .finished(let finished):
            DoneView(
                finished: finished,
                exportURL: store.exportURL(for: finished),
                onRename: { store.rename($0) },
                onCompressAnother: { store.compressAnother() }
            )

        case .nothingToGain(let file, let message):
            NothingToGainView(
                file: file,
                message: message,
                onClose: { store.cancelAndReturnHome() }
            )

        case .failed(let message):
            NothingToGainView(
                file: ImportedFile(url: URL(fileURLWithPath: "/"), displayName: "", byteSize: 0),
                message: message,
                onClose: { store.cancelAndReturnHome() }
            )
        }
    }

    /// Animate between screens, not on every progress tick.
    private var phaseID: String {
        switch store.phase {
        case .home: "home"
        case .analyzing: "analyzing"
        case .ready: "ready"
        case .working: "working"
        case .finished: "finished"
        case .nothingToGain: "nothing"
        case .failed: "failed"
        }
    }
}

/// The parse. Short, but a 28 MB deck is not instant and an empty screen would
/// look like nothing happened.
struct AnalyzingView: View {
    let file: ImportedFile
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Metrics.stackSpacing) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Looking at your PDF…")
                .font(.title3.weight(.medium))
            Text(file.displayName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, Metrics.screenPadding)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
    }
}
