//
//  LyricsWidget.swift
//  LyricsWidgetExtension
//
//  The lyrics Live Activity.
//  - CarPlay Dashboard: the `.small` family (one full canvas; each lyric is one centered line).
//  - iPhone Lock Screen: the `.medium` family (same card, bigger).
//  - iPhone Dynamic Island: icons only in the compact slots (they're one short line tall, too small
//    for lyrics); long-press expands to the full card.
//
//  The card view lives in Shared/LyricsShared.swift so the app can preview it.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsAttributes.self) { context in
            LyricsActivityView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    LyricsCardView(state: context.state, isStale: context.isStale, maxPrimarySize: 20)
                        .frame(height: 64)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.white)
            } compactTrailing: {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(.white.opacity(0.7))
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.white)
            }
        }
        // Opts into CarPlay Dashboard (and Apple Watch Smart Stack) with a full-canvas view.
        .supplementalActivityFamilies([.small])
    }
}

private struct LyricsActivityView: View {
    let state: LyricsAttributes.ContentState
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            // CarPlay: fill the canvas the system gives us.
            LyricsCardView(state: state, isStale: isStale, maxPrimarySize: 28)
                .padding(.horizontal, 6)
        default:
            // iPhone Lock Screen: the system sizes this to its content, so give it a fixed height.
            LyricsCardView(state: state, isStale: isStale, maxPrimarySize: 24)
                .frame(height: 84)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }
}
