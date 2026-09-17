//
//  LyricsWidget.swift
//  LyricsWidgetExtension
//
//  WidgetKit Live Activity interface designed specifically for CarPlay Dashboard:
//  Zero margins, full 100% width edge-to-edge 2-line vertical stack.
//

import WidgetKit
import SwiftUI
import ActivityKit

public struct LyricsWidget: Widget {
    public init() {}
    
    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsAttributes.self) { context in
            // MARK: - 100% Full-Width CarPlay Dashboard & Lock Screen Card
            CarPlayLyricsCardView(state: context.state)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.songTitle)
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.artistName)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CarPlayLyricsCardView(state: context.state)
                }
            } compactLeading: {
                // Left Column (Right-aligned, meets right column at center)
                let (cur1, _) = splitHalf(context.state.currentLine)
                let (nxt1, _) = splitHalf(context.state.nextLine ?? "")
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cur1.isEmpty ? "Waiting..." : cur1)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.trailing)
                    
                    if !nxt1.isEmpty {
                        Text(nxt1)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.60))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } compactTrailing: {
                // Right Column (Left-aligned, continues seamlessly from left column)
                let (_, cur2) = splitHalf(context.state.currentLine)
                let (_, nxt2) = splitHalf(context.state.nextLine ?? "")
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(cur2)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.leading)
                    
                    if !nxt2.isEmpty {
                        Text(nxt2)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.60))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Word Splitter Helper
private func splitHalf(_ text: String) -> (String, String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ("", "") }
    let words = trimmed.split(separator: " ").map(String.init)
    guard words.count > 1 else { return (trimmed, "") }
    let mid = (words.count + 1) / 2
    let first = words[0..<mid].joined(separator: " ")
    let second = words[mid...].joined(separator: " ")
    return (first, second)
}

// MARK: - CarPlay Dashboard & iPhone Lock Screen Presentation (Full 100% Width)
struct CarPlayLyricsCardView: View {
    let state: LyricsAttributes.ContentState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Line 1: Primary Singing Line (Full Width, Bold, Auto-scaling)
            Text(state.currentLine.isEmpty ? "Waiting for lyrics..." : state.currentLine)
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Line 2: Upcoming Next Line (Distinctly smaller, Subtle, Full Width)
            if let next = state.nextLine, !next.isEmpty {
                Text(next)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.60))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
