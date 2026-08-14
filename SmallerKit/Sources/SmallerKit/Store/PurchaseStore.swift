import Foundation
import StoreKit

/// Smaller Pro: one non-consumable, bought once, kept for ever.
///
/// No subscription, no accounts, no server. StoreKit's own transaction history
/// is the source of truth, so "restore" is just asking it again.
public actor PurchaseStore {

    /// The only product. Must match the identifier in `Smaller.storekit` and,
    /// later, in App Store Connect.
    public static let proProductID = "com.leejiles.smaller.pro"

    public enum State: Sendable, Equatable {
        case unknown
        case notPurchased
        case purchased
    }

    public private(set) var state: State = .unknown
    public private(set) var product: Product?

    private var updates: Task<Void, Never>?

    public init() {}

    /// Starts listening for transactions that arrive outside a purchase — a
    /// buy on another device, or a refund. Call once at launch.
    public func start() async {
        await refresh()
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
    }

    deinit {
        updates?.cancel()
    }

    /// Loads the product and re-reads entitlements.
    public func refresh() async {
        if product == nil {
            product = try? await Product.products(for: [Self.proProductID]).first
        }
        state = await hasEntitlement ? .purchased : .notPurchased
    }

    public var isPro: Bool { state == .purchased }

    /// Localized price for the paywall, or nil until the product loads.
    public var displayPrice: String? { product?.displayPrice }

    public enum PurchaseResult: Sendable, Equatable {
        case purchased
        case cancelled
        case pending
        case failed(String)
    }

    public func purchase() async -> PurchaseResult {
        guard let product else { return .failed("The store isn't available right now.") }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    return .failed("That purchase couldn't be verified.")
                }
                await transaction.finish()
                state = .purchased
                return .purchased
            case .userCancelled:
                return .cancelled
            case .pending:
                // Ask-to-buy and similar. Nothing to do but wait; the
                // `Transaction.updates` listener catches the approval.
                return .pending
            @unknown default:
                return .failed("The store returned something we didn't understand.")
            }
        } catch {
            return .failed("The purchase couldn't be completed.")
        }
    }

    /// Restore is a re-read, plus a sync in case this device has never seen the
    /// receipt. Returns whether anything was found.
    public func restore() async -> Bool {
        try? await AppStore.sync()
        await refresh()
        return isPro
    }

    private var hasEntitlement: Bool {
        get async {
            for await entitlement in Transaction.currentEntitlements {
                guard case .verified(let transaction) = entitlement else { continue }
                if transaction.productID == Self.proProductID, transaction.revocationDate == nil {
                    return true
                }
            }
            return false
        }
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        await transaction.finish()
        await refresh()
    }
}
