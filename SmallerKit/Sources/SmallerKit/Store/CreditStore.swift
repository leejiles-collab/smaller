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

    /// The keychain item, scoped to the App Group.
    ///
    /// `kSecAttrAccessGroup` is the whole point of this function. Without it an
    /// item lands in the target's *default* access group, which is its own
    /// `application-identifier` — so the app wrote to
    /// `PT3HD7UTA5.com.leejiles.smaller` and the share extension wrote to
    /// `PT3HD7UTA5.com.leejiles.smaller.share`, two separate items with the same
    /// service and account, each invisible to the other. The count looked shared
    /// only because the App Group defaults were doing the work; the mirror never
    /// agreed, and `used` takes the larger of the two, so a stale extension copy
    /// could silently raise the app's count back up.
    ///
    /// iOS accepts an App Group identifier as a keychain access group when the
    /// target holds that app group entitlement, which both of ours already do.
    /// So this needs no Keychain Sharing capability, no new entitlement and no
    /// provisioning change — the sharing we already declared is enough.
    static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BundleConfig.appGroupID,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: BundleConfig.appGroupID
        ]
    }

    /// The same item as it was stored before the access group was set: in
    /// whichever default group the calling target happened to have.
    ///
    /// Only read, never written. It exists so an existing install does not have
    /// its count silently forgiven on update.
    static func legacyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BundleConfig.appGroupID,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func readKeychain() -> Int? {
        if let shared = read(query()) { return shared }
        // Nothing in the shared group. Before concluding the user has spent
        // nothing, look where this target used to write, and adopt it.
        guard let legacy = read(legacyQuery()) else { return nil }
        writeKeychain(legacy)
        return legacy
    }

    private static func read(_ base: [String: Any]) -> Int? {
        var request = base
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Int(text)
    }

    /// Where the mirror actually lives and what it currently says.
    ///
    /// Diagnostics only. The mirror is unreadable from outside the process by
    /// design, so without something like this a claim about its state can never
    /// be checked — which is how the two halves managed to disagree unnoticed.
    public static func mirrorDiagnostic() -> String {
        let shared = read(query())
        let legacy = read(legacyQuery())
        return "keychain shared=\(shared.map(String.init) ?? "absent")"
            + " legacy=\(legacy.map(String.init) ?? "absent")"
            + " group=\(BundleConfig.appGroupID)"
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
