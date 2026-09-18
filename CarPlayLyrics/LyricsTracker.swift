//
//  LyricsTracker.swift
//  CarPlayLyrics
//
//  Production-ready music tracking, LRCLIB lyrics fetching, LRC parsing,
//  audio delay calibration, and ActivityKit Live Activity synchronization.
//

import Foundation
import MediaPlayer
import ActivityKit
import Combine
import SwiftUI

// MARK: - Parsed Lyric Model
public struct LyricLine: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: TimeInterval
    public let text: String
    
    public init(timestamp: TimeInterval, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

// MARK: - LRCLIB API Response Models
public struct LRCLibResponse: Decodable {
    public let id: Int?
    public let name: String?
    public let trackName: String?
    public let artistName: String?
    public let albumName: String?
    public let duration: Double?
    public let instrumental: Bool?
    public let plainLyrics: String?
    public let syncedLyrics: String?
}

// MARK: - Lyrics Tracker
@MainActor
public final class LyricsTracker: ObservableObject {
    public static let shared = LyricsTracker()
    
    // MARK: - Published Properties for UI
    @Published public var currentTitle: String = "No Track Playing"
    @Published public var currentArtist: String = "Waiting for music..."
    @Published public var currentAlbum: String = ""
    @Published public var currentPlaybackTime: TimeInterval = 0.0
    @Published public var trackDuration: TimeInterval = 0.0
    @Published public var isPlaying: Bool = false
    
    @Published public var currentLine: String = ""
    @Published public var nextLine: String? = nil
    @Published public var isSyncedAvailable: Bool = false
    @Published public var statusMessage: String? = nil
    
    @Published public var isActivityActive: Bool = false
    @Published public var isLiveActivitySupported: Bool = true
    @Published public var isDemoMode: Bool = false
    
    // MARK: - Audio Delay Calibration (Persisted)
    /// User calibration offset in seconds (Bluetooth/CarPlay wireless delay compensation).
    /// Typically 0.5s to 1.5s in vehicle head units.
    @Published public var userDelay: Double {
        didSet {
            UserDefaults.standard.set(userDelay, forKey: "CarPlayLyrics_userDelay")
            // Re-evaluate immediately when slider changes
            syncCurrentTime(playbackTime: currentPlaybackTime)
        }
    }
    
    // MARK: - Private State
    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var parsedLines: [LyricLine] = []
    private var currentActivity: Activity<LyricsAttributes>?
    private var pollingTimer: Timer?
    private var currentFetchTask: Task<Void, Never>?
    private var lyricsCache: [String: LRCLibResponse] = [:]
    
    // Demo mode timer
    private var demoTimer: Timer?
    
    // MARK: - Initialization
    public init() {
        let savedDelay = UserDefaults.standard.double(forKey: "CarPlayLyrics_userDelay")
        // Default to 0.8s if unset (standard Bluetooth A2DP buffer latency)
        self.userDelay = UserDefaults.standard.object(forKey: "CarPlayLyrics_userDelay") != nil ? savedDelay : 0.8
        
        checkActivityKitSupport()
        setupNotificationObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        pollingTimer?.invalidate()
        demoTimer?.invalidate()
    }
    
    // MARK: - Setup & Permissions
    
    public func requestMediaPermission() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                if status == .authorized {
                    self?.startTracking()
                } else {
                    self?.statusMessage = "Media library permission denied"
                }
            }
        }
    }
    
    public func startTracking() {
        guard !isDemoMode else { return }
        
        // Start background silent audio to prevent suspension on lock screen
        SilentAudioPlayer.shared.start()
        
        musicPlayer.beginGeneratingPlaybackNotifications()
        updateNowPlayingItem()
        startPolling()
    }
    
    public func stopTracking() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        musicPlayer.endGeneratingPlaybackNotifications()
        SilentAudioPlayer.shared.stop()
        Task {
            await endCurrentActivity()
        }
    }
    
    private func checkActivityKitSupport() {
        if #available(iOS 16.1, *) {
            isLiveActivitySupported = ActivityAuthorizationInfo().areActivitiesEnabled
        } else {
            isLiveActivitySupported = false
        }
    }
    
    // MARK: - Media Notifications (Steering wheel controls, skips, seeks)
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNowPlayingChange),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackStateChange),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleDidEnterBackground() {
        guard !isDemoMode else { return }
        SilentAudioPlayer.shared.start()
        if pollingTimer == nil {
            startPolling()
        }
        print("[LyricsTracker] App entered background - silent keep-alive active.")
    }
    
    @objc private func handleDidBecomeActive() {
        guard !isDemoMode else { return }
        SilentAudioPlayer.shared.start()
        updateNowPlayingItem()
    }
    
    @objc private func handleNowPlayingChange() {
        guard !isDemoMode else { return }
        Task { @MainActor in
            print("[LyricsTracker] Track changed via system notification.")
            self.updateNowPlayingItem()
        }
    }
    
    @objc private func handlePlaybackStateChange() {
        guard !isDemoMode else { return }
        Task { @MainActor in
            self.isPlaying = (self.musicPlayer.playbackState == .playing)
            if self.isPlaying {
                if self.pollingTimer == nil {
                    self.startPolling()
                }
            }
            // Trigger immediate sync on pause/play
            self.syncCurrentTime(playbackTime: self.musicPlayer.currentPlaybackTime)
        }
    }
    
    // MARK: - Track Processing & LRCLIB Integration
    
    private func updateNowPlayingItem() {
        guard let item = musicPlayer.nowPlayingItem else {
            currentTitle = "No Track Playing"
            currentArtist = "Open Apple Music to play"
            currentAlbum = ""
            trackDuration = 0.0
            parsedLines = []
            currentLine = ""
            nextLine = nil
            isSyncedAvailable = false
            statusMessage = "Waiting for music playback..."
            Task { await endCurrentActivity() }
            return
        }
        
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Track"
        let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Artist"
        let album = item.albumTitle ?? ""
        let duration = item.playbackDuration
        
        // Check if track actually changed
        if title == currentTitle && artist == currentArtist && !parsedLines.isEmpty {
            return
        }
        
        currentTitle = title
        currentArtist = artist
        currentAlbum = album
        trackDuration = duration
        isPlaying = (musicPlayer.playbackState == .playing)
        
        // Reset state for new song
        parsedLines = []
        currentLine = "Loading lyrics..."
        nextLine = nil
        isSyncedAvailable = false
        statusMessage = "Fetching from LRCLIB..."
        
        fetchLyrics(title: title, artist: artist, album: album, duration: duration)
    }
    
    /// Fetches lyrics with cancellation and in-memory cache to prevent duplicate requests
    private func fetchLyrics(title: String, artist: String, album: String, duration: Double) {
        currentFetchTask?.cancel()
        
        let cacheKey = "\(title.lowercased())__\(artist.lowercased())"
        if let cached = lyricsCache[cacheKey] {
            processLyricsResponse(cached, title: title, artist: artist, duration: duration)
            return
        }
        
        currentFetchTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let response = try await self.queryLRCLIB(title: title, artist: artist, album: album, duration: duration)
                guard !Task.isCancelled else { return }
                
                self.lyricsCache[cacheKey] = response
                self.processLyricsResponse(response, title: title, artist: artist, duration: duration)
            } catch {
                guard !Task.isCancelled else { return }
                print("[LyricsTracker] LRCLIB Fetch Error: \(error.localizedDescription)")
                self.handleLyricsFailure(reason: "Lyrics unavailable for this track")
            }
        }
    }
    
    /// LRCLIB Free REST API: queries /api/get first, falls back to /api/search
    private func queryLRCLIB(title: String, artist: String, album: String, duration: Double) async throws -> LRCLibResponse {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ]
        if !album.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("CarPlayLyrics-FreeApp/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            let decoder = JSONDecoder()
            return try decoder.decode(LRCLibResponse.self, from: data)
        }
        
        // Fallback to search endpoint if exact match not found
        var searchComponents = URLComponents(string: "https://lrclib.net/api/search")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: "\(title) \(artist)")
        ]
        
        guard let searchUrl = searchComponents.url else {
            throw URLError(.badURL)
        }
        
        var searchRequest = URLRequest(url: searchUrl)
        searchRequest.timeoutInterval = 8.0
        searchRequest.setValue("CarPlayLyrics-FreeApp/1.0", forHTTPHeaderField: "User-Agent")
        
        let (searchData, searchResponse) = try await URLSession.shared.data(for: searchRequest)
        if let searchHttp = searchResponse as? HTTPURLResponse, searchHttp.statusCode == 200 {
            let decoder = JSONDecoder()
            let list = try decoder.decode([LRCLibResponse].self, from: searchData)
            // Look for first item with syncedLyrics
            if let matched = list.first(where: { $0.syncedLyrics != nil && !($0.syncedLyrics?.isEmpty ?? true) }) ?? list.first {
                return matched
            }
        }
        
        throw URLError(.resourceUnavailable)
    }
    
    private func processLyricsResponse(_ response: LRCLibResponse, title: String, artist: String, duration: Double) {
        if response.instrumental == true {
            self.parsedLines = []
            self.isSyncedAvailable = false
            self.currentLine = "♫ Instrumental ♫"
            self.nextLine = nil
            self.statusMessage = "Instrumental Track"
            self.startOrUpdateActivity(title: title, artist: artist, duration: duration)
            return
        }
        
        if let synced = response.syncedLyrics, !synced.isEmpty {
            let parsed = parseLRC(synced)
            if !parsed.isEmpty {
                self.parsedLines = parsed
                self.isSyncedAvailable = true
                self.statusMessage = nil
                self.startOrUpdateActivity(title: title, artist: artist, duration: duration)
                self.syncCurrentTime(playbackTime: self.musicPlayer.currentPlaybackTime)
                return
            }
        }
        
        // Fallback if only plain lyrics exist
        if let plain = response.plainLyrics, !plain.isEmpty {
            self.parsedLines = []
            self.isSyncedAvailable = false
            self.currentLine = "Lyrics available on phone"
            self.nextLine = nil
            self.statusMessage = "Unsynchronized lyrics only"
            self.startOrUpdateActivity(title: title, artist: artist, duration: duration)
            return
        }
        
        handleLyricsFailure(reason: "No lyrics found on LRCLIB")
    }
    
    private func handleLyricsFailure(reason: String) {
        self.parsedLines = []
        self.isSyncedAvailable = false
        self.currentLine = "Lyrics unavailable"
        self.nextLine = nil
        self.statusMessage = reason
        self.startOrUpdateActivity(title: currentTitle, artist: currentArtist, duration: trackDuration)
    }
    
    // MARK: - LRC Parser
    
    /// Parses LRC content strings with formats [mm:ss.xx] or [mm:ss.xxx]
    public func parseLRC(_ lrcString: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let lines = lrcString.components(separatedBy: .newlines)
        
        // Regex to capture [mm:ss.xx] or [mm:ss.xxx]
        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range) {
                if let minRange = Range(match.range(at: 1), in: trimmed),
                   let secRange = Range(match.range(at: 2), in: trimmed),
                   let msRange = Range(match.range(at: 3), in: trimmed),
                   let textRange = Range(match.range(at: 4), in: trimmed) {
                    
                    let minutes = Double(trimmed[minRange]) ?? 0
                    let seconds = Double(trimmed[secRange]) ?? 0
                    let msRaw = String(trimmed[msRange])
                    let msDivisor = pow(10.0, Double(msRaw.count))
                    let milliseconds = (Double(msRaw) ?? 0) / msDivisor
                    
                    let totalSeconds = (minutes * 60.0) + seconds + milliseconds
                    let text = String(trimmed[textRange]).trimmingCharacters(in: .whitespaces)
                    
                    // Keep empty lines as spacers/instrumental pauses if needed, but filter out pure metadata tags
                    result.append(LyricLine(timestamp: totalSeconds, text: text.isEmpty ? "•••" : text))
                }
            }
        }
        
        return result.sorted { $0.timestamp < $1.timestamp }
    }
    
    private var dispatchTimer: DispatchSourceTimer?
    
    // MARK: - Synchronization Engine (Delay Slider Logic & Background Song Detection)
    
    private func startPolling() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isDemoMode else { return }
            
            // CRITICAL: iOS stops delivering MPMusicPlayerControllerNowPlayingItemDidChange in background.
            // Actively detect song change during background polling:
            if let item = self.musicPlayer.nowPlayingItem {
                let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty && (title != self.currentTitle || artist != self.currentArtist) {
                    print("[LyricsTracker] Background song change detected: '\(title)' by '\(artist)'")
                    self.updateNowPlayingItem()
                    return
                }
            }
            
            self.currentPlaybackTime = self.musicPlayer.currentPlaybackTime
            self.syncCurrentTime(playbackTime: self.currentPlaybackTime)
        }
        timer.resume()
        self.dispatchTimer = timer
    }
    
    /// Evaluates effective time: (currentPlaybackTime - userDelay) and updates lines
    public func syncCurrentTime(playbackTime: TimeInterval) {
        guard isSyncedAvailable, !parsedLines.isEmpty else { return }
        
        // Core latency formula: subtract the wireless Bluetooth/CarPlay latency
        let effectiveTime = max(0.0, playbackTime - userDelay)
        
        // Binary search for highest timestamp <= effectiveTime
        var low = 0
        var high = parsedLines.count - 1
        var matchIndex = -1
        
        while low <= high {
            let mid = (low + high) / 2
            if parsedLines[mid].timestamp <= effectiveTime {
                matchIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        
        var newLine = ""
        var newNextLine: String? = nil
        
        if matchIndex >= 0 {
            newLine = parsedLines[matchIndex].text
            if matchIndex + 1 < parsedLines.count {
                newNextLine = parsedLines[matchIndex + 1].text
            }
        } else if let first = parsedLines.first {
            // Before the first line
            newLine = "♫ \(currentTitle)"
            newNextLine = first.text
        }
        
        if newLine != self.currentLine || newNextLine != self.nextLine {
            self.currentLine = newLine
            self.nextLine = newNextLine
            self.pushActivityUpdate()
        }
    }
    
    // MARK: - ActivityKit Lifecycle Management (Edge-Case Safe)
    
    private func startOrUpdateActivity(title: String, artist: String, duration: Double) {
        guard isLiveActivitySupported else { return }
        
        let state = LyricsAttributes.ContentState(
            currentLine: currentLine,
            nextLine: nextLine,
            songTitle: title,
            artistName: artist,
            isSynced: isSyncedAvailable,
            statusMessage: statusMessage,
            progress: duration > 0 ? (currentPlaybackTime / duration) : 0.0,
            userDelay: userDelay
        )
        
        Task {
            if let activity = currentActivity {
                // Check if current activity belongs to this track
                if activity.attributes.trackId == "\(title)_\(artist)" {
                    let content = ActivityContent(state: state, staleDate: nil)
                    await activity.update(content)
                    return
                } else {
                    // Song changed: end prior activity before launching new one to prevent activity leaks
                    await endCurrentActivity()
                }
            }
            
            // Start fresh activity
            do {
                let attributes = LyricsAttributes(
                    trackId: "\(title)_\(artist)",
                    duration: duration
                )
                let initialContent = ActivityContent(state: state, staleDate: nil)
                let activity = try Activity.request(
                    attributes: attributes,
                    content: initialContent,
                    pushType: nil
                )
                self.currentActivity = activity
                self.isActivityActive = true
                print("[LyricsTracker] Live Activity started successfully: \(activity.id)")
            } catch {
                print("[LyricsTracker] Failed to start Live Activity: \(error.localizedDescription)")
            }
        }
    }
    
    private func pushActivityUpdate() {
        guard let activity = currentActivity else { return }
        
        let state = LyricsAttributes.ContentState(
            currentLine: currentLine,
            nextLine: nextLine,
            songTitle: currentTitle,
            artistName: currentArtist,
            isSynced: isSyncedAvailable,
            statusMessage: statusMessage,
            progress: trackDuration > 0 ? (currentPlaybackTime / trackDuration) : 0.0,
            userDelay: userDelay
        )
        
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.update(content)
        }
    }
    
    public func endCurrentActivity() async {
        guard let activity = currentActivity else { return }
        let finalState = LyricsAttributes.ContentState(
            currentLine: currentLine,
            nextLine: nil,
            songTitle: currentTitle,
            artistName: currentArtist,
            isSynced: isSyncedAvailable,
            statusMessage: "Ended",
            progress: 1.0,
            userDelay: userDelay
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        await activity.end(content, dismissalPolicy: .immediate)
        self.currentActivity = nil
        self.isActivityActive = false
        print("[LyricsTracker] Live Activity ended.")
    }
    
    // MARK: - Simulator & Demo Mode
    
    /// Enables rich simulation for Xcode Simulator without requiring a physical Apple Music library
    public func enableDemoMode() {
        isDemoMode = true
        pollingTimer?.invalidate()
        pollingTimer = nil
        
        currentTitle = "Bohemian Rhapsody"
        currentArtist = "Queen"
        currentAlbum = "A Night at the Opera"
        trackDuration = 180.0
        isPlaying = true
        currentPlaybackTime = 0.0
        
        let sampleLRC = """
        [00:01.00]Is this the real life?
        [00:04.50]Is this just fantasy?
        [00:08.20]Caught in a landslide, no escape from reality
        [00:16.00]Open your eyes, look up to the skies and see
        [00:24.00]I'm just a poor boy, I need no sympathy
        [00:30.50]Because I'm easy come, easy go
        [00:34.00]Little high, little low
        [00:37.00]Any way the wind blows doesn't really matter to me
        [00:46.00]Mama, just killed a man
        [00:52.00]Put a gun against his head, pulled my trigger, now he's dead
        [01:00.00]Mama, life had just begun
        """
        self.parsedLines = parseLRC(sampleLRC)
        self.isSyncedAvailable = true
        self.statusMessage = nil
        self.startOrUpdateActivity(title: currentTitle, artist: currentArtist, duration: trackDuration)
        
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isDemoMode else { return }
                self.currentPlaybackTime += 0.5
                if self.currentPlaybackTime > 75.0 {
                    self.currentPlaybackTime = 0.0
                }
                self.syncCurrentTime(playbackTime: self.currentPlaybackTime)
            }
        }
    }
    
    public func disableDemoMode() {
        demoTimer?.invalidate()
        demoTimer = nil
        isDemoMode = false
        startTracking()
    }
}
