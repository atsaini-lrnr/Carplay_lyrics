//
//  ContentView.swift
//  CarPlayLyrics
//
//  iPhone screen: start/stop, live previews of the CarPlay card, and the audio delay slider.
//  The previews use the same views as the Live Activity (Shared/LyricsShared.swift).
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var tracker = LyricsTracker.shared
    @ObservedObject private var diagnostics = DiagnosticsLog.shared

    private let cardBackground = Color(red: 0.08, green: 0.09, blue: 0.12)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    warnings
                    nowPlaying
                    previews
                    delaySlider
                    controls
                    stallLog
                    if tracker.isDemoMode { layoutTest }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("CarPlay Lyrics")
            .onAppear { tracker.start() }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var warnings: some View {
        if !tracker.liveActivitiesEnabled {
            banner("Live Activities are turned off. Turn them on in Settings → CarPlayLyrics to see lyrics in CarPlay.")
        }
        if tracker.mediaAccessDenied {
            banner("Allow Media & Apple Music access in Settings → CarPlayLyrics so the app can see what's playing.")
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tracker.card.songTitle.isEmpty ? "Nothing playing" : tracker.card.songTitle)
                .font(.headline)
                .lineLimit(1)
            if !tracker.card.artistName.isEmpty {
                Text(tracker.card.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                StatusBadge(title: tracker.isTracking ? "Following playback" : "Stopped",
                            color: tracker.isTracking ? .green : .orange)
                StatusBadge(title: tracker.isActivityActive ? "Card on CarPlay" : "No card",
                            color: tracker.isActivityActive ? .blue : .gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionStyle()
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CARPLAY CARD")
            LyricsCardView(state: tracker.card, maxPrimarySize: 28)
                .padding(.horizontal, 6)
                .frame(height: 96)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))

        }
        .sectionStyle()
    }

    private var delaySlider: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Audio delay", systemImage: "timer")
                    .font(.headline)
                Spacer()
                Text(String(format: "%+.2f s", tracker.userDelay))
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(Color.accentColor)
            }
            Text("Wireless CarPlay and Bluetooth play audio 0.5–1.5 s late. Increase this if lyrics appear before the singer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $tracker.userDelay, in: -0.5...3.0, step: 0.05)
            HStack(spacing: 12) {
                stepButton("−0.1 s") { tracker.userDelay = max(-0.5, tracker.userDelay - 0.1) }
                stepButton("Reset 0.8 s") { tracker.userDelay = 0.8 }
                stepButton("+0.1 s") { tracker.userDelay = min(3.0, tracker.userDelay + 0.1) }
            }
        }
        .sectionStyle()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tracker.isTracking && tracker.isActivityActive {
                Button(role: .destructive) { tracker.stop() } label: {
                    Label("Stop lyrics card", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button { tracker.start(userInitiated: true) } label: {
                    Label("Start lyrics card", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Text("Open the app once before driving. The card then keeps updating with the phone locked, across songs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle(isOn: Binding(get: { tracker.isDemoMode }, set: { tracker.setDemoMode($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo mode")
                    Text("Fake playback with test lines, for the Simulator")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sectionStyle()
    }

    /// Shows when iOS paused the app in the background (the cause of frozen lyrics).
    private var stallLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("DIAGNOSTICS")
                Spacer()
                if !diagnostics.entries.isEmpty {
                    Button("Clear") { diagnostics.clear() }
                        .font(.caption)
                }
            }
            if diagnostics.entries.isEmpty {
                Text("Nothing recorded. The app kept running while locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(diagnostics.entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.caption.monospaced())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionStyle()
    }

    /// The card at several widths, to check that long and Hindi lines fit without cutting off.
    private var layoutTest: some View {
        let samples: [LyricsAttributes.ContentState] = [
            .init(kind: .lyrics, currentLine: "Short line", nextLine: "यह एक छोटी पंक्ति है",
                  songTitle: "", artistName: ""),
            .init(kind: .lyrics, currentLine: "यह एक लंबी परीक्षण पंक्ति है जो कारप्ले स्क्रीन पर पूरी दिखनी चाहिए",
                  nextLine: "मध्यम लंबाई की एक और पंक्ति", songTitle: "", artistName: ""),
            .init(kind: .lyrics,
                  currentLine: "A much longer English test line that has to fit on the card without being cut off",
                  nextLine: "बहुत लंबी पंक्ति: गाड़ी चलाते हुए भी आसानी से पढ़ सकें, इसलिए अक्षर बड़े और साफ़ होने चाहिए",
                  songTitle: "", artistName: ""),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("LAYOUT TEST (240 / 300 PT WIDE)")
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                ForEach([CGFloat(240), 300], id: \.self) { width in
                    LyricsCardView(state: sample, maxPrimarySize: 28)
                        .padding(.horizontal, 6)
                        .frame(width: width, height: 96)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionStyle()
    }

    // MARK: - Helpers


    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
    }

    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private extension View {
    func sectionStyle() -> some View {
        padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
