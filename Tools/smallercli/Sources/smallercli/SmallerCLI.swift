import Foundation
import PDFKit
import SmallerKit

@main
struct SmallerCLI {

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(2)
        }
        arguments.removeFirst()

        do {
            switch command {
            case "inventory":
                try await runInventory(arguments)
            case "compress":
                try await runCompress(arguments)
            case "report":
                try await runReport(arguments)
            case "-h", "--help", "help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        smallercli — SmallerKit test harness

          smallercli inventory <files...>
          smallercli compress --profile sendIt [--profile small ...] <files...> --out DIR
          smallercli report <files...> [--out DIR] > report.md

        Profiles: sendIt, small, tiny
        `report` also runs 5 MB and 2 MB target-size passes and writes
        side-by-side page-1 renders to <out>/visual/.
        """)
    }

    // MARK: - Argument helpers

    struct Options {
        var profiles: [CompressionProfile] = []
        var files: [URL] = []
        var outputDirectory = URL(fileURLWithPath: "/tmp/out")
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--profile":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--profile") }
                guard let profile = profile(named: arguments[index]) else {
                    throw CLIError.unknownProfile(arguments[index])
                }
                options.profiles.append(profile)
            case "--out":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--out") }
                options.outputDirectory = URL(fileURLWithPath: arguments[index])
            default:
                options.files.append(URL(fileURLWithPath: argument))
            }
            index += 1
        }
        if options.profiles.isEmpty { options.profiles = CompressionProfile.presets }
        options.files = options.files.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !options.files.isEmpty else { throw CLIError.noInput }
        return options
    }

    static func profile(named name: String) -> CompressionProfile? {
        CompressionProfile.measured.first { $0.id.lowercased() == name.lowercased() }
    }

    enum CLIError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownProfile(String)
        case noInput

        var description: String {
            switch self {
            case .missingValue(let flag): "\(flag) needs a value"
            case .unknownProfile(let name): "unknown profile '\(name)' (lossless, sendIt, small, tiny)"
            case .noInput: "no .pdf files given"
            }
        }
    }

    // MARK: - inventory

    static func runInventory(_ arguments: [String]) async throws {
        let options = try parse(arguments)
        let engine = try CompressionEngine()

        for file in options.files {
            let inventory = try await engine.inventory(url: file)
            let mix = inventory.pageClassMix
            print("""

            \(file.lastPathComponent)
              size            \(ByteFormat.string(inventory.byteSize)) (\(inventory.byteSize) bytes)
              pages           \(inventory.pageCount)
              images          \(inventory.imageCount) placements, \(inventory.uniqueImages.count) distinct
              image bytes     \(ByteFormat.string(inventory.imageObjectBytes)) (\(percent(inventory.imageByteFraction)) of file)
              unique content  \(ByteFormat.string(inventory.uniqueImageBytes))
              duplicated      \(ByteFormat.string(inventory.duplicateImageBytes)) (\(percent(inventory.duplicateFraction)) of file, free to reclaim)
              addressable     \(ByteFormat.string(inventory.addressableBytes)) (\(percent(inventory.addressableFraction)) of file)
              page mix        scanLike \(mix[.scanLike] ?? 0) · mixed \(mix[.mixed] ?? 0) · vectorOnly \(mix[.vectorOnly] ?? 0)
              text            \(inventory.hasEmbeddedText ? "yes" : "no")
              form fields     \(inventory.hasFormFields ? "yes" : "no")
              encrypted       \(inventory.isEncrypted ? "yes" : "no")
              xref            \(inventory.xrefWasRepaired ? "DAMAGED" : "intact")
              image objects   \(inventory.resolvedImageObjectCount) resolved of \(inventory.rawImageObjectCount) in file\(inventory.hasUnresolvedObjects ? "  <-- CoreGraphics LOST \(inventory.unresolvedImageObjects)" : "")
              worth doing     \(inventory.isWorthCompressing ? "yes" : "no — under \(Int(PDFInventory.worthwhileImageFraction * 100))% images")
              declined        \(inventory.declines.count) distinct (\(ByteFormat.string(inventory.declinedBytes)))
            """)

            let reasons = Dictionary(grouping: inventory.declines, by: { $0.reason })
            for (reason, entries) in reasons.sorted(by: { $0.key.label < $1.key.label }) {
                let bytes = entries.reduce(0) { $0 + $1.usage.totalByteLength }
                print("    declined \(reason.label): \(entries.count) (\(ByteFormat.string(bytes)))")
            }

            for profile in CompressionProfile.measured {
                let estimate = inventory.estimatedSizes[profile] ?? 0
                print("  predict \(profile.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(ByteFormat.string(estimate))")
            }

            let biggest = inventory.uniqueImages.values
                .sorted { $0.rawByteLength > $1.rawByteLength }
                .prefix(5)
            if !biggest.isEmpty {
                print("  largest images:")
                for image in biggest {
                    print(String(
                        format: "    p%-4d %5dx%-5d %-12s %3d bpc  %8s  %6.0f dpi  %@",
                        image.pageIndex + 1, image.pixelWidth, image.pixelHeight,
                        (image.colorSpaceName as NSString).utf8String!, image.bitsPerComponent,
                        (ByteFormat.string(image.rawByteLength) as NSString).utf8String!,
                        image.effectiveDPI,
                        image.isRecodable ? "recodable" : "skipped"
                    ))
                }
            }
        }
    }

    // MARK: - compress

    static func runCompress(_ arguments: [String]) async throws {
        let options = try parse(arguments)
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let engine = try CompressionEngine()

        for file in options.files {
            for profile in options.profiles {
                let started = Date()
                let outcome = try await engine.compress(url: file, profile: profile)
                let elapsed = Date().timeIntervalSince(started)

                switch outcome {
                case .compressed(let result), .bestEffort(let result, _):
                    let destination = options.outputDirectory
                        .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(profile.id).pdf")
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: result.url, to: destination)
                    print(String(
                        format: "%-40s %-7s %10s -> %10s  %3d%% smaller  %.2fs",
                        (file.lastPathComponent as NSString).utf8String!,
                        (profile.id as NSString).utf8String!,
                        (ByteFormat.string(result.originalBytes) as NSString).utf8String!,
                        (ByteFormat.string(result.finalBytes) as NSString).utf8String!,
                        result.reductionPercent, elapsed
                    ))
                    for warning in result.warnings {
                        print("      warning: \(describe(warning))")
                    }
                case .unchanged(let reason):
                    print(String(
                        format: "%-40s %-7s unchanged — %@  %.2fs",
                        (file.lastPathComponent as NSString).utf8String!,
                        (profile.id as NSString).utf8String!,
                        describe(reason), elapsed
                    ))
                }
            }
        }
    }

    // MARK: - report

    static let targets = [5_000_000, 2_000_000]

    static func runReport(_ arguments: [String]) async throws {
        let options = try parse(arguments)
        let visualDirectory = options.outputDirectory.appendingPathComponent("visual")
        try FileManager.default.createDirectory(at: visualDirectory, withIntermediateDirectories: true)

        var documentRows: [String] = []
        var profileRows: [String] = []
        var targetRows: [String] = []
        var predictionErrors: [Double] = []
        var declineTally: [DeclineReason: (count: Int, bytes: Int)] = [:]
        var peakByFile: [(name: String, peak: Int, baseline: Int, largestImage: String)] = []

        print("# Smaller — fixture report")
        print("")
        print("Generated by `smallercli report`. Visual comparisons in `\(visualDirectory.path)`.")
        print("")

        for file in options.files {
            // A fresh engine per file keeps one document's cache from flattering
            // the next one's timings.
            let engine = try CompressionEngine()
            let inventory: PDFInventory
            do {
                inventory = try await engine.inventory(url: file)
            } catch {
                documentRows.append("| \(file.lastPathComponent) | — | — | — | — | — | — | unreadable: \(error) |")
                continue
            }

            let mix = inventory.pageClassMix
            documentRows.append("""
            | \(file.lastPathComponent) | \(ByteFormat.string(inventory.byteSize)) | \(inventory.pageCount) \
            | \(percent(inventory.imageByteFraction)) | \(ByteFormat.string(inventory.uniqueImageBytes)) \
            | \(ByteFormat.string(inventory.duplicateImageBytes)) (\(percent(inventory.duplicateFraction))) \
            | \(percent(inventory.addressableFraction)) \
            | \(mix[.scanLike] ?? 0)/\(mix[.mixed] ?? 0)/\(mix[.vectorOnly] ?? 0) \
            | \(inventory.hasEmbeddedText ? "yes" : "no") | \(inventory.hasFormFields ? "yes" : "no") \
            | \(inventory.xrefWasRepaired ? "**damaged**" : "ok") \
            | \(inventory.resolvedImageObjectCount)/\(inventory.rawImageObjectCount) \
            | \(inventory.declines.count) |
            """)

            var filePeak = 0
            let baseline = Memory.currentResidentBytes()

            for profile in CompressionProfile.measured {
                let predicted = inventory.estimatedSizes[profile] ?? 0
                let started = Date()
                let outcome: CompressionOutcome
                do {
                    let measured = try await Memory.peak {
                        try await engine.compress(url: file, profile: profile)
                    }
                    outcome = measured.value
                    filePeak = max(filePeak, measured.peak)
                } catch {
                    // One awkward fixture must not take the whole report down.
                    profileRows.append("""
                    | \(file.lastPathComponent) | \(profile.id) | \(ByteFormat.string(predicted)) | — | — | — \
                    | — | ERROR | — | \(error) |
                    """)
                    continue
                }
                let elapsed = Date().timeIntervalSince(started)

                switch outcome {
                case .compressed(let result), .bestEffort(let result, _):
                    let error = Double(predicted - result.finalBytes) / Double(max(1, result.finalBytes))
                    predictionErrors.append(error)
                    let textKept = textSurvived(original: file, output: result.url, inventory: inventory)
                    let savings = result.savings
                    for (reason, count) in savings.declinesByReason {
                        let bytes = savings.declinedBytesByReason[reason] ?? 0
                        let existing = declineTally[reason] ?? (0, 0)
                        declineTally[reason] = (max(existing.count, count), max(existing.bytes, bytes))
                    }
                    profileRows.append("""
                    | \(file.lastPathComponent) | \(profile.id) | \(ByteFormat.string(predicted)) \
                    | \(ByteFormat.string(result.finalBytes)) | \(signedPercent(error)) | \(result.reductionPercent)% \
                    | \(ByteFormat.string(savings.dedupBytes)) | \(ByteFormat.string(savings.recodeBytes)) \
                    | \(savings.imagesRecoded)/\(savings.masksRecoded) | \(savings.imagesDeclined) \
                    | \(String(format: "%.2f", elapsed)) | \(String(format: "%.3f", result.pageSimilarity)) | \(textKept) |
                    """)

                    Render.sideBySide(
                        original: file,
                        output: result.url,
                        to: visualDirectory.appendingPathComponent(
                            "\(file.deletingPathExtension().lastPathComponent)-\(profile.id).png"
                        )
                    )

                case .unchanged(let reason):
                    let integrity = if case .failedIntegrity = reason { "**FAIL**" } else { "n/a" }
                    profileRows.append("""
                    | \(file.lastPathComponent) | \(profile.id) | \(ByteFormat.string(predicted)) \
                    | — | — | — | — | — | — | — \
                    | \(String(format: "%.2f", elapsed)) | \(integrity) | \(describe(reason)) |
                    """)
                }
            }

            let biggest = inventory.uniqueImages.values.max { $0.rawByteLength < $1.rawByteLength }
            let describeBiggest = biggest.map {
                "\($0.pixelWidth)x\($0.pixelHeight) \($0.mask == nil ? "" : "+mask ")(\(ByteFormat.string($0.rawByteLength)))"
            } ?? "none"
            peakByFile.append((file.lastPathComponent, filePeak, baseline, describeBiggest))

            for target in targets {
                let started = Date()
                let outcome: CompressionOutcome
                do {
                    outcome = try await engine.compress(url: file, targetBytes: target)
                } catch {
                    targetRows.append("""
                    | \(file.lastPathComponent) | \(ByteFormat.string(target)) | — | — | ERROR: \(error) | — |
                    """)
                    continue
                }
                let elapsed = Date().timeIntervalSince(started)

                switch outcome {
                case .compressed(let result):
                    targetRows.append("""
                    | \(file.lastPathComponent) | \(ByteFormat.string(target)) | \(result.passes) \
                    | \(ByteFormat.string(result.finalBytes)) | met | \(String(format: "%.2f", elapsed)) |
                    """)
                case .bestEffort(let result, let target):
                    targetRows.append("""
                    | \(file.lastPathComponent) | \(ByteFormat.string(target)) | \(result.passes) \
                    | \(ByteFormat.string(result.finalBytes)) | **bottomed out** | \(String(format: "%.2f", elapsed)) |
                    """)
                case .unchanged(let reason):
                    targetRows.append("""
                    | \(file.lastPathComponent) | \(ByteFormat.string(target)) | 0 | — \
                    | \(describe(reason)) | \(String(format: "%.2f", elapsed)) |
                    """)
                }
            }

            await engine.discardOutputs()
        }

        print("## Documents")
        print("")
        print("`dup` is image bytes stored more than once — recoverable at zero quality cost.")
        print("`addressable` is distinct image content we are willing to re-encode.")
        print("")
        print("| file | size | pages | image % | unique imgs | dup | addressable | scan/mixed/vector | text | forms | xref | img objs seen/in file | declined |")
        print("|---|---:|---:|---:|---:|---:|---:|---|---|---|---|---|---:|")
        documentRows.forEach { print($0) }

        print("")
        print("## Profiles")
        print("")
        print("`err` is predicted vs actual: positive means we over-predicted the size.")
        print("`dedup` and `recode` split the saving by mechanism — dedup is free, recode costs quality.")
        print("`imgs` is images recoded / masks rebuilt.")
        print("")
        print("| file | profile | predicted | actual | err | reduction | dedup | recode | imgs | declined | secs | similarity | text kept |")
        print("|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|---|")
        profileRows.forEach { print($0) }

        print("")
        print("## Target size")
        print("")
        print("| file | target | passes | achieved | result | secs |")
        print("|---|---:|---:|---:|---|---:|")
        targetRows.forEach { print($0) }

        print("")
        print("## Declined images")
        print("")
        if declineTally.isEmpty {
            print("Nothing declined across the fixture set.")
        } else {
            print("| reason | distinct images | bytes |")
            print("|---|---:|---:|")
            for (reason, tally) in declineTally.sorted(by: { $0.value.bytes > $1.value.bytes }) {
                print("| \(reason.label) | \(tally.count) | \(ByteFormat.string(tally.bytes)) |")
            }
        }

        print("")
        print("## Peak memory")
        print("")
        print("Footprint sampled during each file's compression. The share extension")
        print("ceiling is around 120 MB, so `over baseline` is the number that matters.")
        print("")
        print("| file | largest image | peak footprint | over baseline |")
        print("|---|---|---:|---:|")
        for entry in peakByFile {
            print("| \(entry.name) | \(entry.largestImage) | \(ByteFormat.string(entry.peak)) "
                + "| \(ByteFormat.string(max(0, entry.peak - entry.baseline))) |")
        }

        if !predictionErrors.isEmpty {
            let absolute = predictionErrors.map(abs).sorted()
            let mean = absolute.reduce(0, +) / Double(absolute.count)
            let median = absolute[absolute.count / 2]
            let within15 = absolute.filter { $0 <= 0.15 }.count
            print("")
            print("## Prediction accuracy")
            print("")
            print("- samples: \(absolute.count)")
            print("- mean absolute error: \(percent(mean))")
            print("- median absolute error: \(percent(median))")
            print("- within ±15%: \(within15)/\(absolute.count)")
            print("")
            print(within15 * 2 >= absolute.count * 2
                  ? "Prediction is good enough to consider surfacing. Still not shown in v1."
                  : "Prediction is not good enough to show a user. Keep it internal.")
        }
    }

    // MARK: - Formatting

    static func textSurvived(original: URL, output: URL, inventory: PDFInventory) -> String {
        guard inventory.hasEmbeddedText else { return "n/a" }
        guard let before = PDFDocument(url: original), let after = PDFDocument(url: output) else { return "?" }
        let beforeText = (before.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let afterText = (after.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if beforeText.isEmpty { return "n/a" }
        if afterText.isEmpty { return "**LOST**" }
        let ratio = Double(afterText.count) / Double(beforeText.count)
        return ratio >= 0.98 ? "yes" : String(format: "%.0f%%", ratio * 100)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    static func describe(_ reason: UnchangedReason) -> String {
        switch reason {
        case .alreadySmall: "already small"
        case .alreadyOptimized: "already optimized"
        case .failedIntegrity(let failure): "integrity: \(failure)"
        case .encrypted: "encrypted"
        case .unsupported(let detail): "unsupported: \(detail)"
        }
    }

    static func describe(_ warning: CompressionWarning) -> String {
        switch warning {
        case .formFieldsPresent: "form fields present"
        case .imagesSkipped(let count, let bytes): "\(count) images skipped (\(ByteFormat.string(bytes)))"
        case .pagesRasterized(let count): "\(count) pages rasterized"
        case .pageFellBackToRaster(let page, let reason): "page \(page + 1) fell back to raster: \(reason)"
        case .hitReadabilityFloor: "hit readability floor"
        case .possibleObjectLoss(let missing, let total): "possible content loss: \(missing)/\(total) image objects unresolved"
        }
    }

    static func warningSummary(_ warnings: [CompressionWarning]) -> String {
        warnings.isEmpty ? "" : warnings.map(describe).joined(separator: "; ")
    }
}
