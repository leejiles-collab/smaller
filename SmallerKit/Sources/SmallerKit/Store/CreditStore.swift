import Foundation
import Security

/// The free tier.
///
/// Lives in the App Group so the app and the share extension share one count,
/// and is mirrored to the Keychain so deleting and reinstalling the app does not
/// hand out a fresh ten. The Keychain copy is the higher of the two on read, so
/// the only way to reset it is to be more determined than this is worth.
///
/// Deliberately not fortified further. Someone who wants to defeat a local
/// counter will, and the hour spent stopping them is better spent on the part of
/// the app people actually paid for.
public actor CreditStore {

    /// TUNING DIAL: how many compressions are free, for ever, before the
    /// paywall appears. One number, one place.
    public static let freeCompressions = 10

    private static let usedKey = "com.smaller.creditsUsed"
    private static let keychainAccount = "creditsUsed"

    private let defaults: UserDefaults?

    public init(suiteName: String = BundleConfig.appGroupID) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    /// Compressions spent so far. Reads both stores and trusts the larger.
    public var used: Int {
        let local = defaults?.integer(forKey: Self.usedKey) ?? 0
        let keychain = Self.readKeychain() ?? 0
        let truth = max(local, keychain)
        // Heal whichever side is behind, so the two agree from here on.
        if local < truth { defaults?.set(truth, forKey: Self.usedKey) }
        if keychain < truth { Self.writeKeychain(truth) }
        return truth
    }

    public var remaining: Int {
        max(0, Self.freeCompressions - used)
    }

    /// True when the next compression needs Pro.
    public var isExhausted: Bool { remaining == 0 }

    /// Spends one credit. Call only for a compression that actually produced a
    /// file — a refusal or a failed integrity check costs the user nothing.
    public func spend() {
        let next = used + 1
        defaults?.set(next, forKey: Self.usedKey)
        Self.writeKeychain(next)
    }

    /// Only for tests and for the simulator's reset affordance.
    public func reset() {
        defaults?.set(0, forKey: Self.usedKey)
        Self.writeKeychain(0)
    }

    // MARK: - Keychain mirror

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BundleConfig.appGroupID,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func readKeychain() -> Int? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Int(text)
    }

    private static func writeKeychain(_ value: Int) {
        let data = Data(String(value).utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query()
            insert[kSecValueData as String] = data
            // Survives reinstall, never leaves the device, and is readable only
            // once the device has been unlocked at least once since boot.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
