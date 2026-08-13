import Foundation

/// Serializes a PDF file object-by-object, straight to disk.
///
/// It writes as it goes rather than assembling the document in memory — the
/// share extension gets roughly 120 MB and a 40 MB scan will not fit twice.
final class PDFWriter {

    enum WriteError: Error {
        case cannotCreateFile(URL)
    }

    let url: URL
    private let handle: FileHandle
    private var byteOffset = 0
    private var buffer: [UInt8] = []
    private var objectOffsets: [Int: Int] = [:]
    private var nextObjectNumber = 1
    private var closed = false

    /// Flush threshold. Keeps syscalls down without holding the file in RAM.
    private static let bufferLimit = 512 * 1024

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WriteError.cannotCreateFile(url)
        }
        self.handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(Self.bufferLimit + 4096)
        append("%PDF-1.7\n")
        // Binary comment marker so tools treat the file as binary.
        appendBytes([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
    }

    // MARK: - Object numbering

    /// Reserves an object number without writing it yet. Reserving up front is
    /// what lets us copy a cyclic object graph (a page points at its parent,
    /// which points back at the page) without recursing forever.
    func allocate() -> Int {
        defer { nextObjectNumber += 1 }
        return nextObjectNumber
    }

    var allocatedCount: Int { nextObjectNumber - 1 }

    // MARK: - Writing objects

    func write(object number: Int, value: PDFValue) throws {
        try beginObject(number)
        appendBytes(value.serialized)
        append("\nendobj\n")
        try flushIfNeeded()
    }

    /// Writes a stream object. `data` is emitted verbatim; `dictionary` must
    /// already describe whatever filters are still applied to it.
    func write(object number: Int, streamDictionary dictionary: [String: PDFValue], data: Data) throws {
        var dict = dictionary
        dict["Length"] = .integer(data.count)
        try beginObject(number)
        appendBytes(PDFValue.dictionary(dict).serialized)
        append("\nstream\n")
        try flushBuffer()
        try handle.write(contentsOf: data)
        byteOffset += data.count
        append("\nendstream\nendobj\n")
        try flushIfNeeded()
    }

    private func beginObject(_ number: Int) throws {
        objectOffsets[number] = byteOffset
        append("\(number) 0 obj\n")
    }

    // MARK: - Finishing

    /// Writes the cross-reference table and trailer. Returns the file size.
    @discardableResult
    func finish(root: Int, info: Int?, documentID: [UInt8]) throws -> Int {
        precondition(!closed, "PDFWriter finished twice")
        closed = true

        // Any object number that was allocated but never written becomes null,
        // otherwise the xref table would point at nothing.
        if allocatedCount > 0 {
            for number in 1...allocatedCount where objectOffsets[number] == nil {
                try write(object: number, value: .null)
            }
        }

        let size = allocatedCount + 1
        let xrefOffset = byteOffset
        append("xref\n0 \(size)\n")
        append("0000000000 65535 f \n")
        if allocatedCount > 0 {
            for number in 1...allocatedCount {
                let off = objectOffsets[number] ?? 0
                append(String(format: "%010d 00000 n \n", off))
            }
        }

        var trailer: [String: PDFValue] = [
            "Size": .integer(size),
            "Root": .reference(root),
            "ID": .array([.string(documentID), .string(documentID)])
        ]
        if let info { trailer["Info"] = .reference(info) }

        append("trailer\n")
        appendBytes(PDFValue.dictionary(trailer).serialized)
        append("\nstartxref\n\(xrefOffset)\n%%EOF\n")

        try flushBuffer()
        try handle.close()
        return byteOffset
    }

    /// Closes the file without a valid trailer — used when we abandon a rebuild.
    func abandon() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Buffered output

    private func append(_ string: String) {
        buffer.append(contentsOf: Array(string.utf8))
        byteOffset += string.utf8.count
    }

    private func appendBytes(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        byteOffset += bytes.count
    }

    private func flushIfNeeded() throws {
        if buffer.count >= Self.bufferLimit { try flushBuffer() }
    }

    private func flushBuffer() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}
