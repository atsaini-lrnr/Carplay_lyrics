//
//  LyricsAttributes.swift
//  CarPlayLyrics & LyricsWidget
//
//  Shared ActivityKit model representing Live Activity metadata and dynamic state.
//  IMPORTANT: Add this file to BOTH 'CarPlayLyrics' (App) and 'LyricsWidget' (Widget Extension) targets.
//

import Foundation
import ActivityKit

public struct LyricsAttributes: ActivityAttributes {
    /// Dynamic state updated in real-time as the song plays
    public struct ContentState: Codable, Hashable {
        /// Active line currently being sung
        public var currentLine: String
        
        /// Upcoming line for anticipation/reading ahead
        public var nextLine: String?
        
        /// Current track title
        public var songTitle: String
        
        /// Current artist name
        public var artistName: String
        
        /// Whether synchronized lyrics are available for this track
        public var isSynced: Bool
        
        /// Optional status alert (e.g. "Instrumental", "Lyrics unavailable", "Buffering...")
        public var statusMessage: String?
        
        /// Playback progress ratio (0.0 to 1.0)
        public var progress: Double
        
        /// Audio delay calibration offset applied (in seconds)
        public var userDelay: Double
        
        public init(
            currentLine: String = "",
            nextLine: String? = nil,
            songTitle: String = "",
            artistName: String = "",
            isSynced: Bool = true,
            statusMessage: String? = nil,
            progress: Double = 0.0,
            userDelay: Double = 0.0
        ) {
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.songTitle = songTitle
            self.artistName = artistName
            self.isSynced = isSynced
            self.statusMessage = statusMessage
            self.progress = progress
            self.userDelay = userDelay
        }
    }
    
    // Static attributes fixed for the duration of an activity session
    public var trackId: String
    public var duration: TimeInterval
    
    public init(trackId: String, duration: TimeInterval) {
        self.trackId = trackId
        self.duration = duration
    }
}
