import Foundation
import UIKit

struct CoverResult: Identifiable, Hashable {
    let id = UUID()
    let full: URL
    let thumb: URL
    let artist: String
    let title: String
    let album: String
}

/// iTunes Search (covers), LRCLIB (lyrics) and YouTube oEmbed (channel name). None need an API key.
enum OnlineServices {
    private static let userAgent = "Encore/1.2 (personal iOS media player)"

    private struct ITunesResponse: Decodable {
        struct Item: Decodable {
            let artworkUrl100: String?
            let artistName: String?
            let trackName: String?
            let collectionName: String?
        }
        let results: [Item]
    }

    static func coverSearch(term: String, kind: MediaKind, limit: Int = 24) async -> [CoverResult] {
        var countries = [Locale.current.region?.identifier ?? "US"]
        if countries[0] != "US" { countries.append("US") }
        for country in countries {
            if let res = try? await itunes(term: term, kind: kind, limit: limit, country: country), !res.isEmpty {
                var seen = Set<URL>()
                return res.filter { seen.insert($0.full).inserted }
            }
        }
        return []
    }

    private static func itunes(term: String, kind: MediaKind, limit: Int, country: String) async throws -> [CoverResult] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "media", value: kind == .video ? "movie" : "music"),
            URLQueryItem(name: "entity", value: kind == .video ? "movie" : "song"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let res = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return res.results.compactMap { item in
            guard let a = item.artworkUrl100, let thumb = URL(string: a),
                  let full = URL(string: a.replacingOccurrences(of: #"/\d+x\d+bb\."#, with: "/600x600bb.", options: .regularExpression))
            else { return nil }
            return CoverResult(full: full, thumb: thumb, artist: item.artistName ?? "",
                               title: item.trackName ?? "", album: item.collectionName ?? "")
        }
    }

    private static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Picks the result that best resembles the track; nil when nothing is close.
    static func bestMatch(_ t: Track, _ results: [CoverResult]) -> CoverResult? {
        let title = norm(t.title), artist = norm(t.artist), album = norm(t.album)
        var best: CoverResult?
        var bestScore = -1
        for r in results {
            var s = 0
            let rt = norm(r.title), ra = norm(r.artist)
            if !title.isEmpty {
                if rt == title { s += 4 } else if rt.contains(title) || title.contains(rt) { s += 2 }
            }
            if !artist.isEmpty {
                if ra == artist { s += 4 } else if ra.contains(artist) || artist.contains(ra) { s += 2 }
            }
            if !album.isEmpty, norm(r.album) == album { s += 2 }
            if s > bestScore { bestScore = s; best = r }
        }
        return bestScore >= 4 ? best : nil
    }

    static func image(_ url: URL) async -> UIImage? {
        guard let res = try? await URLSession.shared.data(from: url),
              (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: res.0)
    }

    // MARK: Lyrics

    private struct LrcItem: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
        let instrumental: Bool?
    }

    private static func lrcRequest(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        return r
    }

    /// Returns synced (LRC) lyrics when available, otherwise plain text.
    static func lyrics(title: String, artist: String, album: String, duration: Double) async -> String? {
        if !artist.isEmpty, duration > 0 {
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            c.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
            ]
            if let res = try? await URLSession.shared.data(for: lrcRequest(c.url!)),
               (res.1 as? HTTPURLResponse)?.statusCode == 200,
               let item = try? JSONDecoder().decode(LrcItem.self, from: res.0),
               let text = item.syncedLyrics?.nonEmpty ?? item.plainLyrics?.nonEmpty {
                return text
            }
        }
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = artist.isEmpty
            ? [URLQueryItem(name: "q", value: title)]
            : [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let res = try? await URLSession.shared.data(for: lrcRequest(s.url!)),
              let items = try? JSONDecoder().decode([LrcItem].self, from: res.0), !items.isEmpty else { return nil }
        let usable = items.filter { $0.instrumental != true && ($0.syncedLyrics?.nonEmpty ?? $0.plainLyrics?.nonEmpty) != nil }
        func closeness(_ i: LrcItem) -> Double { duration > 0 ? abs((i.duration ?? 0) - duration) : 0 }
        let ranked = usable.sorted {
            let a = ($0.syncedLyrics?.nonEmpty != nil ? 0 : 1, closeness($0))
            let b = ($1.syncedLyrics?.nonEmpty != nil ? 0 : 1, closeness($1))
            return a < b
        }
        guard let best = ranked.first, duration <= 0 || closeness(best) < 8 else { return nil }
        return best.syncedLyrics?.nonEmpty ?? best.plainLyrics?.nonEmpty
    }

    // MARK: YouTube oEmbed

    private struct OEmbed: Decodable {
        let title: String?
        let author_name: String?
    }

    static func oEmbed(videoID: String) async -> (title: String, author: String)? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let res = try? await URLSession.shared.data(from: c.url!),
              let o = try? JSONDecoder().decode(OEmbed.self, from: res.0) else { return nil }
        return (o.title ?? "", o.author_name ?? "")
    }
}
