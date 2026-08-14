import SwiftUI
import UniformTypeIdentifiers

/// Wrapper so `fileExporter` can hand over a file we already wrote, without
/// reading it into memory first.
///
/// Shared by the app and the share extension: both offer the user a document
/// picker, and the extension is the one that cannot afford to hold a PDF in
/// memory twice.
public struct ExportedPDF: FileDocument {
    public static var readableContentTypes: [UTType] { [.pdf] }

    public let url: URL

    public init(url: URL) { self.url = url }

    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
