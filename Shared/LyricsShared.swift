//
//  LyricsShared.swift
//  CarPlayLyrics & LyricsWidgetExtension
//
//  Compiled into BOTH targets (the Shared folder belongs to both), so the app,
//  the Live Activity and the in-app preview all use the exact same model and layout.
//

import ActivityKit
import SwiftUI
import UIKit

// MARK: - Live Activity Model

nonisolated struct LyricsAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            /// `currentLine` is a sung lyric line.
            case lyrics
            /// `currentLine` is a status message ("Loading lyrics…", "No lyrics found", …).
            case status
        }

        var kind: Kind
        var currentLine: String
        var nextLine: String
        var songTitle: String
        var artistName: String
        /// Diagnostic: draw the card with plain Text instead of the measured layout, to test whether
        /// the measuring layout is too expensive for iOS to redraw while the phone is locked.
        var plainRender = false

        static let waiting = ContentState(
            kind: .status,
            currentLine: "Waiting for music…",
            nextLine: "Play something in Apple Music",
            songTitle: "",
            artistName: ""
        )
    }
}

// MARK: - Text Measurement & Layout Planning
//
// Why this exists: SwiftUI's `minimumScaleFactor` shrinks each Text row on its own, so rows of one
// lyric end up in different sizes, and `lineLimit` truncates with "…". Instead we measure the real
// text width with UIKit and pick ONE font size and balanced row breaks up front.

nonisolated enum LyricLayout {
    /// Candidate sizes for the sung line, largest first.
    static let primarySizes: [CGFloat] = [28, 26, 24, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13]
    static let minSecondarySize: CGFloat = 11
    /// UIKit measurement and SwiftUI rendering differ by a few points; keep a margin.
    static let widthSafety: CGFloat = 0.94

    static func font(_ size: CGFloat, bold: Bool) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
    }

    static func measure(_ text: String, size: CGFloat, bold: Bool) -> CGSize {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font(size, bold: bold)],
            context: nil
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// Splits `text` into `count` rows at word boundaries so the widest row is as narrow as possible
    /// (rows come out close to equal width). Returns [text] when it can't be split that many ways.
    static func balancedRows(_ text: String, count: Int, size: CGFloat, bold: Bool) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard count > 1, words.count >= count else { return [text] }

        // Measure each word once; a row's width ≈ its words plus the spaces between them.
        let wordWidths = words.map { measure($0, size: size, bold: bold).width }
        let space = measure("a a", size: size, bold: bold).width - 2 * measure("a", size: size, bold: bold).width
        var prefix = [CGFloat(0)]
        for width in wordWidths { prefix.append(prefix.last! + width) }
        func rowWidth(_ from: Int, _ to: Int) -> CGFloat { prefix[to] - prefix[from] + space * CGFloat(to - from - 1) }

        let n = words.count
        var bestCuts: [Int] = []
        var bestWidest = CGFloat.greatestFiniteMagnitude
        if count == 2 {
            for a in 1..<n {
                let widest = max(rowWidth(0, a), rowWidth(a, n))
                if widest < bestWidest { bestWidest = widest; bestCuts = [a] }
            }
        } else {
            for a in 1..<(n - 1) {
                for b in (a + 1)..<n {
                    let widest = max(rowWidth(0, a), rowWidth(a, b), rowWidth(b, n))
                    if widest < bestWidest { bestWidest = widest; bestCuts = [a, b] }
                }
            }
        }

        let bounds = [0] + bestCuts + [n]
        return (0..<(bounds.count - 1)).map { words[bounds[$0]..<bounds[$0 + 1]].joined(separator: " ") }
    }

    // MARK: Full card (CarPlay `.small`, Lock Screen, expanded Dynamic Island)

    struct CardPlan: Equatable {
        /// One entry per visual row of the sung line (1–3 rows).
        var primaryRows: [String]
        var primarySize: CGFloat
        /// Rows of the upcoming line (0–2 rows).
        var secondaryRows: [String]
        var secondarySize: CGFloat
        var spacing: CGFloat
        /// True only when nothing fit; the view then allows wrapping and shrinking as a last resort.
        var isFallback = false
    }

    /// Below this size, prefer an extra row over shrinking the text further (readability while driving).
    static let readableSize: CGFloat = 18

    /// Picks the layout for the card, in this order of preference:
    /// 1. Sung line at a readable size in as few rows as possible, with the full next line under it.
    /// 2. The same at smaller sizes (largest first).
    /// 3. Sung line alone (the next line is hidden rather than cut off).
    /// Text is never truncated except in the last-resort fallback.
    static func cardPlan(primary: String, secondary: String, in canvas: CGSize, maxPrimarySize: CGFloat) -> CardPlan {
        let width = canvas.width * widthSafety
        // Keep a little air above and below so text never touches the card's edges.
        let height = canvas.height - 12
        let sizes = primarySizes.filter { $0 <= maxPrimarySize }
        let readable = sizes.filter { $0 >= readableSize }
        let small = sizes.filter { $0 < readableSize }

        func attempt(size: CGFloat, rowCount: Int, withNext: Bool) -> CardPlan? {
            let rows = balancedRows(primary, count: rowCount, size: size, bold: true)
            guard rows.count == rowCount else { return nil }
            let measured = rows.map { measure($0, size: size, bold: true) }
            guard measured.allSatisfy({ $0.width <= width }) else { return nil }
            let used = measured.reduce(0) { $0 + $1.height }
            guard used <= height else { return nil }

            let spacing = (size * 0.2).rounded()
            guard withNext, !secondary.isEmpty else {
                // No next line shown: zero spacing keeps the sung line exactly centered.
                return CardPlan(primaryRows: rows, primarySize: size, secondaryRows: [],
                                secondarySize: minSecondarySize, spacing: 0)
            }
            guard let (nextRows, nextSize) = secondaryRows(secondary, below: size, width: width,
                                                           heightLeft: height - used - spacing) else { return nil }
            return CardPlan(primaryRows: rows, primarySize: size, secondaryRows: nextRows,
                            secondarySize: nextSize, spacing: spacing)
        }

        for withNext in [true, false] {
            for rowCount in 1...3 {
                for size in readable {
                    if let plan = attempt(size: size, rowCount: rowCount, withNext: withNext) { return plan }
                }
            }
            for size in small {
                for rowCount in 1...3 {
                    if let plan = attempt(size: size, rowCount: rowCount, withNext: withNext) { return plan }
                }
            }
        }

        // Nothing fits cleanly (extremely long line or tiny canvas).
        return CardPlan(primaryRows: [primary], primarySize: sizes.last ?? 13,
                        secondaryRows: [], secondarySize: minSecondarySize, spacing: 0, isFallback: true)
    }

    /// Lays out the whole upcoming line (1 or 2 balanced rows) under a sung line of `primarySize`.
    /// Returns nil when it can't be shown in full; it is then hidden rather than cut off.
    private static func secondaryRows(_ text: String, below primarySize: CGFloat, width: CGFloat,
                                      heightLeft: CGFloat) -> ([String], CGFloat)? {
        let largest = max(minSecondarySize, (primarySize * 0.75).rounded())
        for rowCount in 1...2 {
            for size in stride(from: largest, through: minSecondarySize, by: -1) {
                let rows = balancedRows(text, count: rowCount, size: size, bold: false)
                guard rows.count == rowCount else { break }
                let measured = rows.map { measure($0, size: size, bold: false) }
                if measured.allSatisfy({ $0.width <= width }) && measured.reduce(0, { $0 + $1.height }) <= heightLeft {
                    return (rows, size)
                }
            }
        }
        return nil
    }
}

// MARK: - What the card shows

extension LyricsAttributes.ContentState {
    func displayLines(isStale: Bool) -> (primary: String, secondary: String) {
        if isStale {
            return ("Paused", "Open CarPlayLyrics to resume")
        }
        return (currentLine.isEmpty ? "♪" : currentLine, nextLine)
    }
}

// MARK: - Full Card View (CarPlay `.small`, Lock Screen, expanded Dynamic Island)

/// Every lyric row is one centered Text, so the line reads as one seamless piece.
/// Fills whatever canvas it is given; give it a fixed height where the system doesn't.
struct LyricsCardView: View {
    let state: LyricsAttributes.ContentState
    var isStale = false
    var maxPrimarySize: CGFloat = 24

    var body: some View {
        if state.plainRender {
            let lines = state.displayLines(isStale: isStale)
            VStack(spacing: 4) {
                Text(lines.primary)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text(lines.secondary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            measuredBody
        }
    }

    private var measuredBody: some View {
        GeometryReader { geo in
            let lines = state.displayLines(isStale: isStale)
            let plan = LyricLayout.cardPlan(primary: lines.primary, secondary: lines.secondary,
                                            in: geo.size, maxPrimarySize: maxPrimarySize)
            let primaryColor: Color = (state.kind == .lyrics && !isStale) ? .white : .white.opacity(0.85)

            VStack(spacing: plan.spacing) {
                VStack(spacing: 0) {
                    ForEach(Array(plan.primaryRows.enumerated()), id: \.offset) { _, row in
                        Text(row)
                            .font(.system(size: plan.primarySize, weight: .bold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(plan.isFallback ? 3 : 1)
                            .minimumScaleFactor(plan.isFallback ? 0.7 : 1)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(plan.secondaryRows.enumerated()), id: \.offset) { _, row in
                        Text(row)
                            .font(.system(size: plan.secondarySize, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
