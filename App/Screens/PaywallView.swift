import SwiftUI
import SmallerKit

/// Shown once, when the free compressions are gone and the user is trying to do
/// another one.
///
/// No countdown, no crossed-out price, no "3 people are looking at this". One
/// sentence about what it is, the price, a way to buy it, a way to restore it,
/// and a way to close it.
struct PaywallView: View {
    let purchases: PurchaseStore
    let onPurchased: () -> Void
    let onClose: () -> Void

    @State private var price: String?
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: Metrics.stackSpacing) {
            Spacer()

            VStack(spacing: 10) {
                Text("Smaller Pro")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Unlimited compressions, for ever. One payment, no subscription.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Text("You've used your \(CreditStore.freeCompressions) free compressions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)

                Button("Restore Purchases") { restore() }
                    .font(.callout)
                    .disabled(isWorking)
            }

            Spacer().frame(height: 20)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .frame(maxWidth: 520)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", action: onClose)
            }
        }
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
            case .pending:
                message = "That purchase needs approval. We'll unlock it as soon as it goes through."
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
