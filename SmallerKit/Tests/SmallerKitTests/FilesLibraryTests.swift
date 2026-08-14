import Testing
import Foundation
@testable import SmallerKit

/// Naming and collisions for the folder the user actually opens.
///
/// The rule that matters: nothing already in that folder is ever overwritten.
/// Someone compressing the same deck twice at two settings wants both copies,
/// and the one already on disk is not ours to replace.
struct FilesLibraryTests {

    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-library-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try Data("pdf".utf8).write(to: url)
    }

    @Test func outputNameAppendsSmallerAndKeepsTheStem() {
        #expect(FilesLibrary.outputName(for: "Board Deck.pdf") == "Board Deck-smaller.pdf")
        // Names with dots in them keep everything but the final extension.
        #expect(FilesLibrary.outputName(for: "2026.Q1.report.pdf") == "2026.Q1.report-smaller.pdf")
        // No extension at all still produces a PDF name.
        #expect(FilesLibrary.outputName(for: "scan") == "scan-smaller.pdf")
    }

    @Test func firstSaveUsesTheNameAsGiven() throws {
        let directory = try makeDirectory("first")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = FilesLibrary.uniqueURL(in: directory, preferredName: "Deck-smaller.pdf")
        #expect(url.lastPathComponent == "Deck-smaller.pdf")
    }

    @Test func collisionsStepToDashTwoThenDashThree() throws {
        let directory = try makeDirectory("collide")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FilesLibrary.uniqueURL(in: directory, preferredName: "Deck-smaller.pdf")
        try touch(first)
        let second = FilesLibrary.uniqueURL(in: directory, preferredName: "Deck-smaller.pdf")
        try touch(second)
        let third = FilesLibrary.uniqueURL(in: directory, preferredName: "Deck-smaller.pdf")

        #expect(first.lastPathComponent == "Deck-smaller.pdf")
        #expect(second.lastPathComponent == "Deck-smaller-2.pdf")
        #expect(third.lastPathComponent == "Deck-smaller-3.pdf")
    }

    @Test func savingTwiceLeavesBothFiles() throws {
        let source = try makeDirectory("source")
        let directory = try makeDirectory("keep-both")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = source.appendingPathComponent("Deck.pdf")
        try touch(file)

        let name = FilesLibrary.outputName(for: "Deck.pdf")
        let first = FilesLibrary.uniqueURL(in: directory, preferredName: name)
        try FileManager.default.copyItem(at: file, to: first)
        let second = FilesLibrary.uniqueURL(in: directory, preferredName: name)
        try FileManager.default.copyItem(at: file, to: second)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(contents == ["Deck-smaller-2.pdf", "Deck-smaller.pdf"])
    }

    /// A gap in the sequence is filled rather than skipped past — deleting
    /// `-2` and compressing again should reuse `-2`, not jump to `-4`.
    @Test func aDeletedNumberIsReused() throws {
        let directory = try makeDirectory("gap")
        defer { try? FileManager.default.removeItem(at: directory) }

        try touch(directory.appendingPathComponent("Deck-smaller.pdf"))
        try touch(directory.appendingPathComponent("Deck-smaller-3.pdf"))

        let next = FilesLibrary.uniqueURL(in: directory, preferredName: "Deck-smaller.pdf")
        #expect(next.lastPathComponent == "Deck-smaller-2.pdf")
    }
}
