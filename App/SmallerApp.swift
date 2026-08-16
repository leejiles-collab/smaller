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

#if DEBUG
/// Sets the free-compression counter from a launch argument.
///
/// Only reachable in a debug build — `#if DEBUG` means none of this exists in
/// anything that ships, and a launch argument that rewrites entitlement state
/// has no business in a Release binary.
///
/// It exists because the counter is deliberately hard to clear: it lives in the
/// App Group *and* the Keychain, and the Keychain copy survives deleting the
/// app, which is the whole point of the mirror. That also makes it unreachable
/// from outside the process, so resetting it for a demo recording has to happen
/// in here.
///
///     xcrun devicectl device process launch --device <id> \
///         com.leejiles.smaller --set-credits-used=0
///
/// Uses only CreditStore's ordinary API — reset, then spend N times — so no
/// arbitrary setter has to exist on the type where production code could reach
/// for it.
enum DemoCredits {
    static func applyIfRequested() async {
        let prefix = "--set-credits-used="
        guard let argument = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(prefix) }),
              let requested = Int(argument.dropFirst(prefix.count))
        else { return }

        let target = min(max(requested, 0), CreditStore.freeCompressions)
        let credits = CreditStore()
        await credits.reset()
        for _ in 0..<target { await credits.spend() }

        // Read both stores back rather than trusting the writes. The Keychain
        // mirror is the half that cannot be inspected from outside the process,
        // so if it is not confirmed here it is not confirmed anywhere — and a
        // silently-failed reset would only surface halfway through a recording.
        let used = await credits.used
        let remaining = await credits.remaining
        let report = "requested=\(target) used=\(used) remaining=\(remaining)\n"
            + CreditStore.mirrorDiagnostic() + "\n"
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? report.write(
                to: caches.appendingPathComponent("demo-credits.txt"),
                atomically: true, encoding: .utf8
            )
        }
    }
}
#endif

/// One screen at a time, chosen by what the engine is doing.
struct RootView: View {
    @State private var store = CompressionStore()

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: phaseID)
        }
        .task {
            #if DEBUG
            await DemoCredits.applyIfRequested()
            #endif
            // First, before anything else: file whatever the share extension
            // saved while we were not running. It cannot reach the Files folder
            // from its own sandbox, so this is the moment its work shows up.
            store.adoptExtensionOutput()
            await store.refreshEntitlements()
            SharedContainer.sweep()
        }
        .onOpenURL { url in
            // smaller://open?name=<file> — the share extension handing over a
            // document it was too memory-constrained to do itself.
            guard url.scheme == "smaller", url.host == "open",
                  let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "name" })?.value
            else { return }
            store.openHandoff(named: name)
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
                onClose: { store.cancelAndReturnHome() },
                creditNote: store.shouldMentionCredits
                    ? "\(store.creditsRemaining) free compressions left"
                    : nil
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
                saved: store.saved,
                onSave: { store.fileIntoLibrary(finished) },
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

        case .paywall:
            PaywallView(
                purchases: store.purchases,
                onPurchased: { store.purchased() },
                onClose: { store.dismissPaywall() }
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
        case .paywall: "paywall"
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
