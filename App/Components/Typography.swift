import SwiftUI
import SmallerKit

/// The whole type system. Rounded for numbers, system for prose, and every size
/// expressed as a text style so Dynamic Type moves all of it.
extension Font {

    /// The one huge number on the Done screen.
    static var hugeNumber: Font {
        .system(.largeTitle, design: .rounded, weight: .bold)
    }

    /// Sizes on the analysis screen and the progress percentage.
    static var bigNumber: Font {
        .system(.title, design: .rounded, weight: .semibold)
    }

    static var cardTitle: Font {
        .system(.headline, design: .default, weight: .semibold)
    }

    static var cardDetail: Font {
        .system(.subheadline, design: .default)
    }

    static var wordmark: Font {
        .system(.largeTitle, design: .rounded, weight: .bold)
    }
}

/// Byte counts as VoiceOver should say them.
///
/// "27.2 MB" is read out as "twenty-seven point two em bee", which is not what
/// anyone means. The Done screen's whole job is to state two numbers and the
/// difference between them, so those numbers are spelled out for the screen
/// reader even though the visible label stays short.
enum SpokenBytes {
    static func string(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "%.1f megabytes", mb)
        }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f kilobytes", kb)
    }
}

/// Layout constants, so the generous whitespace is consistent rather than
/// re-invented per screen.
enum Metrics {
    static let screenPadding: CGFloat = 24
    static let stackSpacing: CGFloat = 20
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 18
    static let cornerRadius: CGFloat = 16
}
