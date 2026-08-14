import SwiftUI
import SmallerKit

/// The paywall, in sheet form.
///
/// It appears at exactly one moment: the free compressions are gone and the
/// user is trying to do another one. No timers, no crossed-out prices, no
/// "limited offer". One sentence, one price, one button, and a way back out.
struct SharePaywallView: View {
    let purchases: PurchaseStore
    let onPurchased: () -> Void
    let onOpenApp: () -> Void

    @State private var price: String?
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Text("You've used your \(CreditStore.freeCompressions) free compressions")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Smaller Pro unlocks unlimited compressions, for ever. One payment, no subscription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                buy()
            } label: {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(price.map { "Get Smaller Pro — \($0)" } ?? "Get Smaller Pro")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: 260)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)

            Button("Restore Purchases") { restore() }
                .font(.footnote)
                .disabled(isWorking)

            Spacer()
        }
        .padding(.horizontal, 24)
        .task {
            await purchases.start()
            price = await purchases.displayPrice
            if await purchases.isPro { onPurchased() }
        }
    }

    private func buy() {
        isWorking = true
        message = nil
        Task {
            let result = await purchases.purchase()
            isWorking = false
            switch result {
            case .purchased: onPurchased()
            case .cancelled: break
            case .pending: message = "That purchase needs approval. We'll unlock it once it goes through."
            case .failed(let text): message = text
            }
        }
    }

    private func restore() {
        isWorking = true
        message = nil
        Task {
            let restored = await purchases.restore()
            isWorking = false
            if restored {
                onPurchased()
            } else {
                message = "No previous purchase found on this Apple Account."
            }
        }
    }
}
