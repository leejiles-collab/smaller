import SwiftUI

/// Ring, percentage, and a Cancel that always works.
struct WorkingView: View {
    let file: ImportedFile
    let progress: CompressionStore.Progress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Metrics.stackSpacing) {
            Spacer()

            ProgressRing(fraction: progress.fraction)

            VStack(spacing: 6) {
                Text(progress.subtitle)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(file.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)

            Spacer()
        }
        .padding(.horizontal, Metrics.screenPadding)
        .frame(maxWidth: 520)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Always present, always live. Cancelling stops the task and
                // drops its temporary files; it does not dim and wait for work
                // that is still running underneath.
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .interactiveDismissDisabled()
    }
}
