import Foundation

/// One instance per slideshow. Only recent choices and played stream IDs survive the session.
@MainActor
final class OnlineMusicRecommendations {
    typealias Track = OnlineSlideshowPlaylist.Track
    private let defaults: UserDefaults
    private let choicesKey = "PhotoEarth.onlineMusic.recentCategoryChoices"
    private let playedKey = "PhotoEarth.onlineMusic.recentStreams"
    private var frozenTracks: [Track]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var recentCategoryChoices: [String] { defaults.stringArray(forKey: choicesKey) ?? [] }
    var recentlyPlayedStreams: [String] { defaults.stringArray(forKey: playedKey) ?? [] }

    func recordChoice(_ track: Track) {
        defaults.set(Array(recentCategoryChoices.suffix(23)) + [track.themeID], forKey: choicesKey)
    }

    func recordPlayback(_ track: Track) {
        let id = track.id.absoluteString
        var recent = recentlyPlayedStreams
        guard recent.last != id else { return }
        recent.removeAll { $0 == id }
        defaults.set(Array(recent.suffix(35)) + [id], forKey: playedKey)
    }

    func resetSession() { frozenTracks = nil }

    func playlists(for catalog: [OnlineSlideshowPlaylist]) -> [OnlineSlideshowPlaylist] {
        var random = SystemRandomNumberGenerator()
        return playlists(for: catalog, using: &random)
    }

    func playlists(for catalog: [OnlineSlideshowPlaylist], using random: inout some RandomNumberGenerator) -> [OnlineSlideshowPlaylist] {
        var tracks: [Track] = []
        if let frozenTracks {
            // Preserve order across refreshes, but honor withdrawn streams and corrected metadata.
            let available = Dictionary(grouping: catalog.flatMap(\.tracks), by: \.id)
            tracks = frozenTracks.compactMap { old in
                available[old.id]?.first { $0.themeID == old.themeID }
            }
        }
        if tracks.isEmpty {
            tracks = Self.draw(from: catalog, choices: recentCategoryChoices,
                               played: Set(recentlyPlayedStreams), using: &random)
        }
        guard !tracks.isEmpty else { return catalog }
        frozenTracks = tracks
        return [OnlineSlideshowPlaylist(id: OnlineSlideshowPlaylist.recommendedID,
                                       tracks: tracks, presentation: nil)] + catalog
    }

    private static func draw(from catalog: [OnlineSlideshowPlaylist], choices: [String], played: Set<String>,
                             using random: inout some RandomNumberGenerator) -> [Track] {
        let categoryIDs = catalog.map(\.id)
        let counts = Dictionary(grouping: choices.filter(categoryIDs.contains), by: { $0 }).mapValues(\.count)
        var pools: [String: [Track]] = [:]
        for playlist in catalog {
            let shuffled = playlist.tracks.shuffled(using: &random)
            // popLast draws unheard tracks first.
            pools[playlist.id] = shuffled.filter { played.contains($0.id.absoluteString) }
                + shuffled.filter { !played.contains($0.id.absoluteString) }
        }
        var result: [Track] = []
        var used: Set<URL> = []
        let limit = min(18, categoryIDs.count * 2)
        for round in 0..<2 {
            var remaining = categoryIDs
            let onePerCategory = round == 0 || counts.isEmpty
            let end = round == 0 ? min(categoryIDs.count, limit) : limit
            while result.count < end && !remaining.isEmpty {
                let alternatives = remaining.filter { $0 != result.last?.themeID }
                let eligible = alternatives.isEmpty ? remaining : alternatives
                // A recent explicit choice adds one ticket, capped to preserve variety.
                let tickets = eligible.flatMap { id in Array(repeating: id, count: 1 + min(counts[id, default: 0], 6)) }
                guard let id = tickets.randomElement(using: &random) else { break }
                var next = pools[id]?.popLast()
                while let duplicate = next, used.contains(duplicate.id) { next = pools[id]?.popLast() }
                if let next {
                    used.insert(next.id)
                    result.append(next)
                }
                if onePerCategory || pools[id]?.isEmpty == true { remaining.removeAll { $0 == id } }
            }
        }
        return result
    }
}
