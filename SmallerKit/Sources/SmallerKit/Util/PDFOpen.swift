import Foundation
import CoreGraphics
import PDFKit

/// The one place a PDF is opened.
///
/// ## Why every open goes through here
///
/// Most corporate PDFs are encrypted. DocuSign, Salesforce, Adobe and every CRM
/// exporter ship files with an *owner* password set and the *user* password
/// left empty: the file carries permission flags saying "no copying", but there
/// is no secret and anyone can read it. Preview opens them without a prompt and
/// so does CoreGraphics.
///
/// `CGPDFDocument.isEncrypted` is therefore useless as a refusal test — it is true for the
/// ordinary corporate PDF. The question that matters is whether the document is
/// *unlocked*, and if it is not, whether the empty password unlocks it. Only a
/// file that fails that is genuinely password-protected.
public enum PDFOpen {

    /// Opens a document and unlocks it if the empty password will do.
    public static func document(at url: URL) -> CGPDFDocument? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("")
        }
        return document
    }

    /// True when the file needs a password we do not have.
    public static func isLocked(_ document: CGPDFDocument) -> Bool {
        document.isEncrypted && !document.isUnlocked
    }

    /// PDFKit equivalent, used by the integrity gate's text check.
    public static func pdfKitDocument(at url: URL) -> PDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked {
            _ = document.unlock(withPassword: "")
        }
        return document.isLocked ? nil : document
    }
}
