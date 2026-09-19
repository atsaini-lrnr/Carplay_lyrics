//
//  LyricsTracker.swift
//  CarPlayLyrics
//
//  Follows Apple Music playback, fetches synced lyrics from LRCLIB, and keeps the Live Activity
//  showing the current and next line.
//

import ActivityKit
import Combine
import Foundation
import MediaPlayer
import UIKit

struct LyricLine: Equatable {
    let time: TimeInterval
    /// Empty text marks an instrumental gap.
    let text: String
}

/// Playback state at one instant, from Apple Music or from demo mode.
private struct PlaybackSnapshot {
    let trackKey: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let time: TimeInterval
    let isPlaying: Bool
}

@MainActor
final class LyricsTracker: ObservableObject {
    static let shared = LyricsTracker()

    /// What the Live Activity (and the in-app preview) currently shows.
    @Published private(set) var card = LyricsAttributes.ContentState.waiting
    @Published private(set) var isActivityActive = false
    @Published private(set) var liveActivitiesEnabled = true
    @Published private(set) var isTracking = false
    @Published private(set) var isDemoMode = false
    @Published private(set) var mediaAccessDenied = false

    /// Bluetooth / wireless CarPlay audio lag compensation, in seconds.
    @Published var userDelay: Double {
        didSet {
            UserDefaults.standard.set(userDelay, forKey: Self.delayKey)
            tick()
        }
    }

    private enum LyricsState: Equatable {
        case none, loading, synced, unsynced, instrumental, notFound
    }

    private static let delayKey = "CarPlayLyrics_userDelay"
    /// Stop the keep-alive after this long with nothing playing, so the phone doesn't drain in a pocket.
    private static let idleTimeout: TimeInterval = 20 * 60

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let activity = LiveActivityController()
    private let lrclib = LRCLibClient()

    private var timer: DispatchSourceTimer?
    private var timerIsFast = false
    private var trackKey: String?
    private var title = ""
    private var artist = ""
    private var lines: [LyricLine] = []
    private var lyricsState = LyricsState.none
    private var fetchTask: Task<Void, Never>?
    private var notPlayingSince: Date?
    private var demoStart = Date()
    /// Set by the Stop button so returning to the app doesn't silently restart the card.
    private var stoppedByUser = false
    private var lastTickAt: Date?
    /// What was going on at the last tick, for describing freezes.
    private var lastTickContext = ""
    private var lastHeartbeatAt = Date.distantPast

    private init() {
        userDelay = UserDefaults.standard.object(forKey: Self.delayKey) as? Double ?? 0.8
        activity.onActiveChange = { [weak self] active in self?.isActivityActive = active }

        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            center.addObserver(forName: name, object: player, queue: .main) { _ in
                MainActor.assumeIsolated { LyricsTracker.shared.tick() }
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LyricsTracker.shared.start() }
        }

        if ProcessInfo.processInfo.arguments.contains("-demo") {
            isDemoMode = true
        }
    }

    // MARK: - Start / Stop

    /// Starts following playback and starts the Live Activity. Must run while the app is on screen,
    /// because iOS only allows starting a Live Activity from the foreground.
    /// `userInitiated` is true for the Start button; automatic starts (launch, returning to the app)
    /// respect an earlier Stop.
    func start(userInitiated: Bool = false) {
        if userInitiated { stoppedByUser = false }
        guard !stoppedByUser else { return }
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

        guard isDemoMode || MPMediaLibrary.authorizationStatus() == .authorized else {
            MPMediaLibrary.requestAuthorization { status in
                Task { @MainActor in
                    let tracker = LyricsTracker.shared
                    tracker.mediaAccessDenied = status != .authorized
                    if status == .authorized { tracker.start() }
                }
            }
            return
        }
        mediaAccessDenied = false

        if !isTracking && !isDemoMode { player.beginGeneratingPlaybackNotifications() }
        SilentAudioPlayer.shared.start()
        LocationKeepAlive.shared.start()
        isTracking = true
        notPlayingSince = nil
        tick()
        activity.startIfNeeded(with: card)
        scheduleTimer(fast: true)
    }

    /// Stops everything and removes the card (the "Stop" button).
    func stop() {
        stoppedByUser = true
        pauseTracking()
        Task { await activity.end() }
    }

    func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        pauseTracking()
        isDemoMode = enabled
        demoStart = Date()
        resetTrack()
        start(userInitiated: true)
    }

    private func pauseTracking() {
        if isTracking && !isDemoMode { player.endGeneratingPlaybackNotifications() }
        timer?.cancel()
        timer = nil
        lastTickAt = nil
        fetchTask?.cancel()
        SilentAudioPlayer.shared.stop()
        LocationKeepAlive.shared.stop()
        isTracking = false
    }

    // MARK: - Tick (every 0.25 s while playing, 1 s while paused)

    private func tick() {
        guard isTracking else { return }
        recordStallIfAny()
        SilentAudioPlayer.shared.resumeIfNeeded()
        activity.refreshIfOld()

        guard let snapshot = currentSnapshot() else {
            if trackKey != nil { resetTrack() }
            publish(.waiting)
            handleNotPlaying()
            return
        }

        if snapshot.trackKey != trackKey {
            load(snapshot)
        }

        if snapshot.isPlaying {
            notPlayingSince = nil
            scheduleTimer(fast: true)
        } else {
            handleNotPlaying()
        }
        guard isTracking else { return }

        publish(makeCard(at: snapshot.time))
        heartbeat(snapshot)
    }

    /// Every 5 s, prints what the app sees (visible with `devicectl ... --console`).
    private func heartbeat(_ snapshot: PlaybackSnapshot) {
        guard Date().timeIntervalSince(lastHeartbeatAt) >= 5 else { return }
        lastHeartbeatAt = Date()
        print("[heartbeat] \(Self.appStateDescription) | playing=\(snapshot.isPlaying) "
              + "time=\(String(format: "%.1f", snapshot.time)) | \(snapshot.title) | line=\(card.currentLine)")
    }

    private static var appStateDescription: String {
        let app = UIApplication.shared
        switch app.applicationState {
        case .active: return "app open"
        case .inactive: return "app inactive"
        default: return app.isProtectedDataAvailable ? "background" : "locked"
        }
    }

    private func handleNotPlaying() {
        let since = notPlayingSince ?? Date()
        notPlayingSince = since
        scheduleTimer(fast: false)

        if Date().timeIntervalSince(since) > Self.idleTimeout {
            pauseTracking()
            publish(LyricsAttributes.ContentState(kind: .status, currentLine: "Paused",
                                                  nextLine: "Open CarPlayLyrics to resume",
                                                  songTitle: title, artistName: artist))
        }
    }

    /// Ticks run at least every second while tracking; a longer gap means iOS suspended the app.
    private func recordStallIfAny() {
        let now = Date()
        let context = "\(Self.appStateDescription), audio keep-alive \(SilentAudioPlayer.shared.isPlaying ? "on" : "OFF"), "
            + "location keep-alive \(LocationKeepAlive.shared.isRunning ? "on" : "OFF")"
        defer {
            lastTickAt = now
            lastTickContext = context
        }
        guard let last = lastTickAt, now.timeIntervalSince(last) > 5 else { return }

        let start = last.formatted(date: .omitted, time: .standard)
        DiagnosticsLog.shared.add("FROZE \(Int(now.timeIntervalSince(last))) s from \(start). Before: \(lastTickContext). "
                                  + "Woke up: \(Self.appStateDescription)")
    }

    private func scheduleTimer(fast: Bool) {
        guard timer == nil || fast != timerIsFast else { return }
        timer?.cancel()
        timerIsFast = fast

        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = fast ? .milliseconds(250) : .seconds(1)
        newTimer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        newTimer.setEventHandler {
            MainActor.assumeIsolated { LyricsTracker.shared.tick() }
        }
        newTimer.resume()
        timer = newTimer
    }

    private func publish(_ newCard: LyricsAttributes.ContentState) {
        guard newCard != card else { return }
        card = newCard
        activity.update(newCard)
    }

    // MARK: - Playback Source

    private func currentSnapshot() -> PlaybackSnapshot? {
        if isDemoMode {
            let loop = DemoLyrics.duration
            return PlaybackSnapshot(trackKey: "demo", title: "Layout Demo", artist: "CarPlayLyrics",
                                    album: "", duration: loop,
                                    time: Date().timeIntervalSince(demoStart).truncatingRemainder(dividingBy: loop),
                                    isPlaying: true)
        }
        guard let item = player.nowPlayingItem else { return nil }
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PlaybackSnapshot(
            trackKey: "\(item.persistentID)|\(item.playbackStoreID)|\(title)|\(artist)",
            title: title.isEmpty ? "Unknown Track" : title,
            artist: artist,
            album: item.albumTitle ?? "",
            duration: item.playbackDuration,
            time: player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0,
            isPlaying: player.playbackState == .playing
        )
    }

    // MARK: - Lyrics Loading

    private func resetTrack() {
        fetchTask?.cancel()
        trackKey = nil
        title = ""
        artist = ""
        lines = []
        lyricsState = .none
    }

    private func load(_ snapshot: PlaybackSnapshot) {
        resetTrack()
        trackKey = snapshot.trackKey
        title = snapshot.title
        artist = snapshot.artist

        if isDemoMode {
            lines = LRCParser.parse(DemoLyrics.lrc)
            lyricsState = .synced
            return
        }

        lyricsState = .loading
        let key = snapshot.trackKey
        fetchTask = Task { [lrclib] in
            let result = await lrclib.lyrics(title: snapshot.title, artist: snapshot.artist,
                                             album: snapshot.album, duration: snapshot.duration)
            guard !Task.isCancelled else { return }
            let tracker = LyricsTracker.shared
            guard tracker.trackKey == key else { return }
            tracker.apply(result)
        }
    }

    private func apply(_ result: LRCLibClient.Result) {
        switch result {
        case .synced(let parsed):
            lines = parsed
            lyricsState = .synced
        case .unsynced:
            lyricsState = .unsynced
        case .instrumental:
            lyricsState = .instrumental
        case .notFound:
            lyricsState = .notFound
        }
        tick()
    }

    // MARK: - Card Content

    private func makeCard(at playbackTime: TimeInterval) -> LyricsAttributes.ContentState {
        let songLine = artist.isEmpty ? title : "\(title) · \(artist)"
        func status(_ message: String) -> LyricsAttributes.ContentState {
            LyricsAttributes.ContentState(kind: .status, currentLine: message, nextLine: songLine,
                                          songTitle: title, artistName: artist)
        }

        switch lyricsState {
        case .none: return .waiting
        case .loading: return status("Loading lyrics…")
        case .notFound: return status("No synced lyrics for this song")
        case .unsynced: return status("Only unsynced lyrics exist")
        case .instrumental: return status("♪ Instrumental ♪")
        case .synced: break
        }

        let time = max(0, playbackTime - userDelay)
        // Last line whose timestamp has passed.
        var low = 0, high = lines.count - 1, index = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { index = mid; low = mid + 1 } else { high = mid - 1 }
        }

        let current = index >= 0 ? lines[index].text : ""
        let next = lines[(index + 1)...].first { !$0.text.isEmpty }?.text ?? ""
        return LyricsAttributes.ContentState(kind: .lyrics, currentLine: current.isEmpty ? "♪" : current,
                                             nextLine: next, songTitle: title, artistName: artist)
    }
}

// MARK: - LRC Parser

enum LRCParser {
    /// Handles `[mm:ss.xx]`, `[mm:ss]`, several timestamps per line, `[offset:±ms]`,
    /// and strips word-level `<mm:ss.xx>` tags.
    static func parse(_ lrc: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var result: [LyricLine] = []

        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            var rest = rawLine.drop { $0 == " " }
            var times: [TimeInterval] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:") {
                    offset = (Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }

            let text = String(rest)
                .replacing(/<\d+:\d+(?:[.:]\d+)?>/, with: "")
                .trimmingCharacters(in: .whitespaces)
            for time in times {
                result.append(LyricLine(time: max(0, time - offset), text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }
        // Seconds may be "ss", "ss.xx" or "ss:xx".
        guard let seconds = Double(parts[1].replacingOccurrences(of: ":", with: ".")) else { return nil }
        return minutes * 60 + seconds
    }
}

// MARK: - Demo Mode (Simulator testing; original placeholder text, not song lyrics)

enum DemoLyrics {
    static let duration: TimeInterval = 44
    static let lrc = """
    [00:01.00]Demo mode: test lines to check the layout
    [00:05.00]Short line
    [00:09.00]यह एक छोटी पंक्ति है
    [00:13.00]यह एक लंबी परीक्षण पंक्ति है जो कारप्ले स्क्रीन पर पूरी दिखनी चाहिए
    [00:19.00]
    [00:22.00]A much longer English test line that has to fit on the card without being cut off
    [00:28.00]मध्यम लंबाई की एक और पंक्ति
    [00:32.00]बहुत लंबी पंक्ति: गाड़ी चलाते हुए भी आसानी से पढ़ सकें, इसलिए अक्षर बड़े और साफ़ होने चाहिए
    [00:39.00]Last line, then the demo loops
    """
}
