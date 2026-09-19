//
//  LRCLibClient.swift
//  CarPlayLyrics
//
//  Looks up synced lyrics on LRCLIB (https://lrclib.net), a free community database.
//  Coverage is not complete: songs missing there show "No synced lyrics for this song".
//

import Foundation

final class LRCLibClient {
    enum Result: Equatable {
        case synced([LyricLine])
        case unsynced
        case instrumental
        case notFound
    }

    private struct Track: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
        var hasPlain: Bool { !(plainLyrics ?? "").isEmpty }
    }

    /// Search results within this many seconds of the playing song count as the same recording.
    /// Title-only searches return many unrelated songs, so length is what keeps matches honest.
    private static let durationTolerance: Double = 4
    private static let maxAttempts = 3

    private var cache: [String: Result] = [:]

    func lyrics(title: String, artist: String, album: String, duration: TimeInterval) async -> Result {
        let cacheKey = "\(title.lowercased())|\(artist.lowercased())|\(Int(duration))"
        if let cached = cache[cacheKey] { return cached }

        // Retry network failures (patchy mobile data in the car); don't cache them.
        for attempt in 1...Self.maxAttempts {
            do {
                let result = try await lookup(title: title, artist: artist, album: album, duration: duration)
                cache[cacheKey] = result
                return result
            } catch is CancellationError {
                return .notFound
            } catch {
                print("[LRCLIB] Attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { return .notFound }
            }
        }
        return .notFound
    }

    private func lookup(title: String, artist: String, album: String, duration: TimeInterval) async throws -> Result {
        let cleanTitle = Self.cleanTitle(title)
        let mainArtist = Self.mainArtist(artist)
        var plainFallback = false

        // 1) Exact match on title + artist + album + length. LRCLIB rejects (400) an empty artist or a
        //    length outside 1–3600 s, so only try it when both are usable.
        var exact = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: artist),
                     URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
        if !album.isEmpty { exact.append(URLQueryItem(name: "album_name", value: album)) }
        let canGetExact = !artist.isEmpty && (1...3600).contains(duration)
        if canGetExact, let track: Track = try await get("get", exact) {
            if track.instrumental == true { return .instrumental }
            if let lines = Self.parsed(track) { return .synced(lines) }
            plainFallback = track.hasPlain
        }

        // 2) Searches from most to least specific; each result must match the song's length.
        var searches: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: mainArtist)],
            [URLQueryItem(name: "track_name", value: cleanTitle), URLQueryItem(name: "artist_name", value: mainArtist)],
            [URLQueryItem(name: "q", value: "\(cleanTitle) \(mainArtist)")],
        ]
        // Title-only search returns many unrelated songs; only safe when length can confirm the match.
        if duration > 0 {
            searches.append([URLQueryItem(name: "track_name", value: cleanTitle)])
        }
        searches = searches.reduce(into: []) { unique, query in if !unique.contains(query) { unique.append(query) } }

        for query in searches {
            let results: [Track] = try await get("search", query) ?? []
            // Unknown length: only accept results by the same (main) artist.
            let sameLength = results.filter {
                duration > 0 || Self.mainArtist($0.artistName ?? "").lowercased() == mainArtist.lowercased()
            }.filter {
                duration <= 0 || abs(($0.duration ?? -1_000) - duration) <= Self.durationTolerance
            }
            if let match = sameLength.first(where: \.hasSynced), let lines = Self.parsed(match) {
                return .synced(lines)
            }
            if sameLength.contains(where: { $0.instrumental == true }) { return .instrumental }
            if sameLength.contains(where: \.hasPlain) { plainFallback = true }
        }

        return plainFallback ? .unsynced : .notFound
    }

    private static func parsed(_ track: Track) -> [LyricLine]? {
        guard track.hasSynced, let synced = track.syncedLyrics else { return nil }
        let lines = LRCParser.parse(synced)
        return lines.isEmpty ? nil : lines
    }

    /// GET https://lrclib.net/api/<endpoint>. Returns nil on 404 (not found).
    private func get<T: Decodable>(_ endpoint: String, _ query: [URLQueryItem]) async throws -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        request.setValue("CarPlayLyrics/1.0 (personal project)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 = not in the database; other 4xx (except rate limiting) = this query can't match.
        if status == 404 || ((400..<500).contains(status) && status != 429) { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Title / Artist Cleanup

    /// "Kesariya (From \"Brahmastra\")" → "Kesariya"; "Song - Remastered 2011" → "Song"; drops "feat." parts.
    static func cleanTitle(_ title: String) -> String {
        var result = title
            .replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
            .replacing(/(?i)\s+(feat\.?|ft\.?|featuring)\s.*$/, with: "")
        if let dash = result.range(of: " - ") {
            result = String(result[..<dash.lowerBound])
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? title : result
    }

    /// "Irfana & Kalla Sha" → "Irfana"; "A, B" → "A"; "A feat. B" → "A".
    static func mainArtist(_ artist: String) -> String {
        let first = artist
            .replacing(/(?i)\s+(feat\.?|ft\.?|featuring|x|with)\s.*$/, with: "")
            .split(whereSeparator: { $0 == "," || $0 == "&" || $0 == "/" })
            .first
            .map(String.init) ?? artist
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }
}
