//
//  DiagnosticsLog.swift
//  CarPlayLyrics
//
//  Small persistent log shown at the bottom of the app: background freezes (with what was going
//  on at the time), audio interruptions and keep-alive failures. Used to diagnose frozen lyrics.
//

import Combine
import Foundation

@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    /// Newest first.
    @Published private(set) var entries: [String]

    private static let key = "CarPlayLyrics_diagnostics"
    private static let maxEntries = 30

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func add(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        entries = Array((["\(time)  \(message)"] + entries).prefix(Self.maxEntries))
        UserDefaults.standard.set(entries, forKey: Self.key)
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
