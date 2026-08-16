import Testing
import Foundation
import CoreGraphics
import CoreText
import Security
@testable import SmallerKit

/// The gates that decide whether a file is touched at all, and the counter that
/// decides whether the user is allowed to.
struct GateAndStoreTests {

    // MARK: - Encryption

    /// The empty-owner-password case: the file says "encrypted", has no secret,
    /// and every CRM in the world exports them. Refusing these refused two of
    /// seven real fixtures.
    @Test func ownerPasswordOnlyPDFIsOpenedNotRefused() async throws {
        let workspace = try TempWorkspace(name: "test-owner-password")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "owner-locked.pdf")

        Self.makeEncryptedPDF(at: url, ownerPassword: "secret", userPassword: nil)

        let document = try #require(PDFOpen.document(at: url))
        #expect(document.isEncrypted)
        #expect(PDFOpen.isLocked(document) == false)

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.isLocked == false)
        #expect(inventory.pageCount == 2)
    }

    /// A real user password is a real refusal, and says so.
    @Test func userPasswordPDFIsRefusedAsLocked() async throws {
        let workspace = try TempWorkspace(name: "test-user-password")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "user-locked.pdf")

        Self.makeEncryptedPDF(at: url, ownerPassword: "owner", userPassword: "letmein")

        guard let document = PDFOpen.document(at: url) else {
            // CoreGraphics can refuse to open it at all, which is also a refusal.
            return
        }
        #expect(PDFOpen.isLocked(document))

        let engine = try CompressionEngine()
        if let inventory = try? InventoryBuilder.build(url: url) {
            #expect(inventory.isLocked)
            let outcome = try await engine.compress(url: url, profile: .sendIt)
            guard case .unchanged(let reason) = outcome else {
                Issue.record("expected a refusal, got \(outcome)")
                return
            }
            #expect(reason == .encrypted)
            #expect(reason.userMessage == "This PDF is password-protected.")
        }
    }

    // MARK: - Size and integrity gates

    /// Output that is not meaningfully smaller is not worth shipping, and the
    /// original is handed back instead.
    @Test func outputNoSmallerThanTheInputIsRefused() async throws {
        let workspace = try TempWorkspace(name: "test-size-gate")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "text.pdf")
        Self.makeTextPDF(at: url, pages: 3)

        let engine = try CompressionEngine()
        let outcome = try await engine.compress(url: url, profile: .tiny)

        guard case .unchanged(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason == .alreadySmall || reason == .alreadyOptimized)
        // A refusal must never cost the user one of their free compressions.
        #expect(outcome.burnsCredit == false)
    }

    /// The threshold itself, so the gate cannot drift without a test noticing.
    @Test func sizeGateThresholdIsWhatWeThinkItIs() {
        #expect(CompressionEngine.sizeGateThreshold == 0.98)
        #expect(CompressionEngine.objectLossFloor == 3)
        #expect(CompressionEngine.objectLossTolerance == 0.25)
    }

    /// Wholesale object loss is refused; a stray unresolved object is not. A
    /// form whose single image hides in an annotation appearance stream trips
    /// the fraction test at one-of-one and must still be processed.
    @Test func objectLossNeedsMoreThanOneMissingImage() {
        #expect(CompressionEngine.objectLossFloor > 1)
    }

    // MARK: - Free credits

    @Test func creditsCountDownAndSurviveBeingReRead() async {
        let suite = "test-credits-\(UUID().uuidString)"
        let store = CreditStore(suiteName: suite)
        await store.reset()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        #expect(await store.remaining == CreditStore.freeCompressions)
        #expect(await store.isExhausted == false)

        await store.spend()
        #expect(await store.used == 1)
        #expect(await store.remaining == CreditStore.freeCompressions - 1)

        for _ in 1..<CreditStore.freeCompressions { await store.spend() }
        #expect(await store.remaining == 0)
        #expect(await store.isExhausted)

        // Spending past zero must not wrap into a negative allowance.
        await store.spend()
        #expect(await store.remaining == 0)
        await store.reset()
    }

    @Test func freeCompressionCountIsASingleNamedDial() {
        #expect(CreditStore.freeCompressions == 10)
    }

    // MARK: - The extension's budget

    @Test func oversizedFilesAreHandedToTheApp() throws {
        let workspace = try TempWorkspace(name: "test-budget")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "small.pdf")
        Self.makeTextPDF(at: url, pages: 1)

        let inventory = try InventoryBuilder.build(url: url)
        #expect(ShareBudget.canRunInExtension(inventory))
        #expect(ShareBudget.maxInputBytes > 0)
        #expect(ShareBudget.maxImagePixels > 0)
    }

    // MARK: - Fixtures

    /// A PDF with a name that iOS produces constantly: spaces, parentheses and
    /// a non-ASCII character. Percent-encoding any of this into a filesystem
    /// path would break it.
    @Test func awkwardFilenamesAreOpenedNotMangled() async throws {
        let workspace = try TempWorkspace(name: "test-filenames")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "Report (final) — Scan 3.pdf")
        Self.makeTextPDF(at: url, pages: 1)

        let document = PDFOpen.document(at: url)
        #expect(document != nil)

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.pageCount == 1)
    }

    /// A zero-byte file is an interrupted download, not a broken PDF, and is
    /// reported as its own thing.
    @Test func emptyFileIsRejectedByName() throws {
        let workspace = try TempWorkspace(name: "test-empty")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "empty.pdf")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        #expect(throws: (any Error).self) {
            try InventoryBuilder.build(url: url)
        }
    }

    // MARK: - Helpers

    static func makeTextPDF(at url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0, alpha: 1)
            context.textPosition = CGPoint(x: 72, y: 700)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Page \(page + 1) of a document with nothing to compress.",
                attributes: [.font: font]
            ) as CFAttributedString)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Builds an encrypted PDF. With `userPassword` nil this is exactly the
    /// shape every CRM exporter produces: permissions set, no secret to know.
    static func makeEncryptedPDF(at url: URL, ownerPassword: String, userPassword: String?) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [String: Any] = [
            kCGPDFContextOwnerPassword as String: ownerPassword,
            kCGPDFContextAllowsCopying as String: false
        ]
        if let userPassword {
            info[kCGPDFContextUserPassword as String] = userPassword
        }
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
        else { return }
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// The free-tier counter is supposed to be one number shared by the app and the
/// share extension. It was not.
struct CreditSharingTests {

    /// The app wrote its keychain mirror to `PT3HD7UTA5.com.leejiles.smaller`
    /// and the extension wrote to `PT3HD7UTA5.com.leejiles.smaller.share`,
    /// because neither set an access group and each target falls back to its own
    /// `application-identifier`. Two items, same service, same account, each
    /// invisible to the other.
    ///
    /// It hid because the App Group defaults *are* shared and normally lead. It
    /// surfaced when the app's copy was reset and the extension's was not: the
    /// extension still read its own 10, and `used` takes the larger of the two
    /// and heals the smaller upward, so the extension would have written 10 back
    /// into the shared defaults and re-exhausted the app.
    @Test func theKeychainMirrorIsScopedToTheAppGroup() {
        let query = CreditStore.query()
        let group = query[kSecAttrAccessGroup as String] as? String
        #expect(group == BundleConfig.appGroupID,
                "mirror not scoped to the app group: app and extension keep separate counts")
        #expect(query[kSecAttrService as String] as? String == BundleConfig.appGroupID)
        #expect(query[kSecAttrAccount as String] as? String != nil)
    }

    /// The migration source, and the only thing it may differ by.
    ///
    /// It must stay unscoped: that is what lets it find an item written before
    /// the access group existed, so updating does not forgive everyone's used
    /// credits.
    @Test func theLegacyQueryIsUnscopedAndOtherwiseIdentical() {
        let current = CreditStore.query()
        let legacy = CreditStore.legacyQuery()

        #expect(legacy[kSecAttrAccessGroup as String] as? String == nil,
                "the legacy query is scoped, so it can no longer find pre-update items")
        #expect(legacy[kSecAttrService as String] as? String
                == current[kSecAttrService as String] as? String)
        #expect(legacy[kSecAttrAccount as String] as? String
                == current[kSecAttrAccount as String] as? String)
        #expect(legacy[kSecClass as String] as? String
                == current[kSecClass as String] as? String)
    }

    /// Both halves of the store must name the same App Group, or "shared count"
    /// means nothing.
    @Test func bothStoresNameTheSameAppGroup() {
        #expect(BundleConfig.appGroupID == "group.\(BundleConfig.prefix).smaller")
        #expect(CreditStore.query()[kSecAttrAccessGroup as String] as? String
                == BundleConfig.appGroupID)
    }
}
