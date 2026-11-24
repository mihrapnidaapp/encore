import SwiftUI
import Foundation
import UIKit

// MARK: - Paths and preferences

enum Paths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// Visible in the Files app: On My iPhone › MJV Player › Media
    static var media: URL { documents.appendingPathComponent("Media", isDirectory: true) }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MJVPlayer", isDirectory: true)
    }
    static var artwork: URL { support.appendingPathComponent("Artwork", isDirectory: true) }
    static var libraryFile: URL { support.appendingPathComponent("library.json") }
    static var temp: URL { FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true) }

    static func ensure() {
        for dir in [media, artwork, temp] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

enum Prefs {
    static let autoCovers = "autoCovers"
    static let autoLyrics = "autoLyrics"
    static let cleanTitles = "cleanTitles"
    static let remoteFallback = "remoteFallback"
    static let videoHeight = "videoHeight"
    static let resumeLong = "resumeLong"

    static func register() {
        UserDefaults.standard.register(defaults: [
            autoCovers: true, autoLyrics: true, cleanTitles: true,
            remoteFallback: true, videoHeight: 1080, resumeLong: true,
        ])
    }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let t = Int(seconds.rounded(.down))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - Models

enum MediaKind: String, Codable, Hashable { case audio, video }

struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: MediaKind = .audio
    var fileName = ""
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    var year = ""
    var trackNumber: Int?
    var duration: Double = 0
    var artworkFile: String?
    var dateAdded = Date()
    var lastPlayed: Date?
    var playCount = 0
    var favorite = false
    var source = "files"
    var sourceURL: String?
    var channel: String?
    var notes: String?
    var lyrics: String?
    var resumePosition: Double?

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, kind, fileName, title, artist, album, genre, year, trackNumber, duration, artworkFile,
             dateAdded, lastPlayed, playCount, favorite, source, sourceURL, channel, notes, lyrics, resumePosition
    }

    // Tolerant decoding so new fields never break an existing library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        kind = v(.kind, MediaKind.audio)
        title = v(.title, "")
        artist = v(.artist, "")
        album = v(.album, "")
        genre = v(.genre, "")
        year = v(.year, "")
        trackNumber = v(.trackNumber, Int?.none)
        duration = v(.duration, 0.0)
        artworkFile = v(.artworkFile, String?.none)
        dateAdded = v(.dateAdded, Date())
        lastPlayed = v(.lastPlayed, Date?.none)
        playCount = v(.playCount, 0)
        favorite = v(.favorite, false)
        source = v(.source, "files")
        sourceURL = v(.sourceURL, String?.none)
        channel = v(.channel, String?.none)
        notes = v(.notes, String?.none)
        lyrics = v(.lyrics, String?.none)
        resumePosition = v(.resumePosition, Double?.none)
    }

    var displayTitle: String { title.nonEmpty ?? (fileName as NSString).deletingPathExtension }
    var displayArtist: String {
        artist.nonEmpty ?? channel?.nonEmpty ?? (kind == .video ? "Video" : "Unknown Artist")
    }
    var subtitle: String {
        [displayArtist, album.nonEmpty].compactMap { $0 }.joined(separator: " · ")
    }
    var isFromYouTube: Bool { source == "youtube" }

    func matches(_ query: String) -> Bool {
        let q = query.trimmed
        if q.isEmpty { return true }
        return [title, artist, album, channel ?? "", genre].contains { $0.localizedStandardContains(q) }
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var created = Date()
}

struct Album: Identifiable {
    let id: String
    let name: String
    let artist: String
    let year: String
    let tracks: [Track]
    var cover: Track? { tracks.first { $0.artworkFile != nil } ?? tracks.first }
}

struct Artist: Identifiable {
    let id: String
    let name: String
    let tracks: [Track]
    var cover: Track? { tracks.first { $0.artworkFile != nil } ?? tracks.first }
}

enum TrackSort: String, CaseIterable, Identifiable {
    case title = "Title", artist = "Artist", album = "Album", added = "Recently Added",
         played = "Recently Played", plays = "Most Played", duration = "Duration"
    var id: String { rawValue }

    func apply(_ list: [Track]) -> [Track] {
        func asc(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        switch self {
        case .title: return list.sorted { asc($0.displayTitle, $1.displayTitle) }
        case .artist:
            return list.sorted {
                if $0.displayArtist != $1.displayArtist { return asc($0.displayArtist, $1.displayArtist) }
                if $0.album != $1.album { return asc($0.album, $1.album) }
                return ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999)
            }
        case .album:
            return list.sorted {
                if $0.album != $1.album { return asc($0.album, $1.album) }
                return ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999)
            }
        case .added: return list.sorted { $0.dateAdded > $1.dateAdded }
        case .played: return list.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .plays: return list.sorted { $0.playCount > $1.playCount }
        case .duration: return list.sorted { $0.duration > $1.duration }
        }
    }
}

// MARK: - Library store

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var tracks: [Track] = [] { didSet { reindex() } }
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var importing = false

    private var indexByID: [UUID: Int] = [:]
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
    }

    init() {
        Paths.ensure()
        if let data = try? Data(contentsOf: Paths.libraryFile),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            tracks = snap.tracks
            playlists = snap.playlists
        }
        reindex()
    }

    private func reindex() {
        var map: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() { map[t.id] = i }
        indexByID = map
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        let snap = Snapshot(tracks: tracks, playlists: playlists)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(snap) {
                try? data.write(to: Paths.libraryFile, options: .atomic)
            }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        if let data = try? JSONEncoder().encode(Snapshot(tracks: tracks, playlists: playlists)) {
            try? data.write(to: Paths.libraryFile, options: .atomic)
        }
    }

    // MARK: Lookup

    func track(_ id: UUID) -> Track? {
        guard let i = indexByID[id], tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }
    func fileURL(_ t: Track) -> URL { Paths.media.appendingPathComponent(t.fileName) }
    func artworkURL(_ t: Track) -> URL? { t.artworkFile.map { Paths.artwork.appendingPathComponent($0) } }

    var songs: [Track] { tracks.filter { $0.kind == .audio } }
    var videos: [Track] { tracks.filter { $0.kind == .video } }

    var albums: [Album] {
        let groups = Dictionary(grouping: songs.filter { !$0.album.trimmed.isEmpty }) { $0.album.trimmed.lowercased() }
        return groups.map { key, list in
            let sorted = list.sorted {
                if ($0.trackNumber ?? 999) != ($1.trackNumber ?? 999) { return ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999) }
                return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
            let artists = Set(list.map { $0.artist.trimmed.lowercased() })
            let artist = artists.count > 1 ? "Various Artists" : (list.first?.displayArtist ?? "")
            let year = list.compactMap { $0.year.nonEmpty }.first ?? ""
            return Album(id: key, name: list[0].album.trimmed, artist: artist, year: year, tracks: sorted)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var artists: [Artist] {
        let groups = Dictionary(grouping: songs) { $0.displayArtist.lowercased() }
        return groups.map { key, list in
            Artist(id: key, name: list[0].displayArtist, tracks: TrackSort.album.apply(list))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func album(_ id: String) -> Album? { albums.first { $0.id == id } }

    // MARK: Editing

    func add(_ new: [Track]) {
        guard !new.isEmpty else { return }
        tracks.append(contentsOf: new)
        scheduleSave()
    }

    func update(_ t: Track) {
        guard let i = indexByID[t.id] else { return }
        tracks[i] = t
        scheduleSave()
    }

    func mutate(_ id: UUID, _ body: (inout Track) -> Void) {
        guard let i = indexByID[id] else { return }
        var t = tracks[i]
        body(&t)
        tracks[i] = t
        scheduleSave()
    }

    func toggleFavorite(_ id: UUID) { mutate(id) { $0.favorite.toggle() } }

    func markPlayed(_ id: UUID) {
        mutate(id) {
            $0.playCount += 1
            $0.lastPlayed = Date()
        }
    }

    func setResume(_ id: UUID, _ position: Double?) {
        guard let t = track(id), t.resumePosition != position else { return }
        mutate(id) { $0.resumePosition = position }
    }

    func setArtwork(_ id: UUID, image: UIImage, square: Bool) {
        guard let name = ImageTools.saveArtwork(image, square: square) else { return }
        mutate(id) { t in
            if let old = t.artworkFile { try? FileManager.default.removeItem(at: Paths.artwork.appendingPathComponent(old)) }
            t.artworkFile = name
        }
        PlayerEngine.shared.refreshNowPlaying(id)
    }

    func removeArtwork(_ id: UUID) {
        mutate(id) { t in
            if let old = t.artworkFile { try? FileManager.default.removeItem(at: Paths.artwork.appendingPathComponent(old)) }
            t.artworkFile = nil
        }
        PlayerEngine.shared.refreshNowPlaying(id)
    }

    func delete(_ ids: Set<UUID>) {
        let fm = FileManager.default
        for t in tracks where ids.contains(t.id) {
            try? fm.removeItem(at: fileURL(t))
            if let a = artworkURL(t) { try? fm.removeItem(at: a) }
        }
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        scheduleSave()
    }

    // MARK: Playlists

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }
    func tracks(in p: Playlist) -> [Track] { p.trackIDs.compactMap { track($0) } }

    @discardableResult
    func createPlaylist(_ name: String, trackIDs: [UUID] = []) -> Playlist {
        let p = Playlist(name: name.nonEmpty ?? "New Playlist", trackIDs: trackIDs)
        playlists.append(p)
        scheduleSave()
        return p
    }
    func renamePlaylist(_ id: UUID, _ name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), let n = name.nonEmpty else { return }
        playlists[i].name = n
        scheduleSave()
    }
    func deletePlaylists(at offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
        scheduleSave()
    }
    func addToPlaylist(_ id: UUID, _ ids: [UUID]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.append(contentsOf: ids)
        scheduleSave()
    }
    func removeFromPlaylist(_ id: UUID, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets)
        scheduleSave()
    }
    func movePlaylistTracks(_ id: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    // MARK: Import

    func importFiles(_ urls: [URL], move: Bool = false, silent: Bool = false) async {
        guard !urls.isEmpty else { return }
        importing = true
        if !silent { AppState.shared.showToast("Importing…") }
        let result = await MediaImporter.importBatch(urls, move: move)
        add(result.tracks)
        importing = false
        if !silent || !result.tracks.isEmpty {
            var msg = result.tracks.isEmpty ? "Nothing was imported" : "Imported \(result.tracks.count) item(s)"
            if result.failed > 0 { msg += ", \(result.failed) failed" }
            AppState.shared.showToast(msg)
        }
        if Prefs.bool(Prefs.autoCovers) { await fetchMissingCovers(result.tracks) }
    }

    /// Files copied into the app's Documents folder (Files app, Finder or iTunes file sharing) are imported.
    func scanInbox(silent: Bool) async {
        let fm = FileManager.default
        var found: [URL] = []
        let roots = [Paths.documents, Paths.documents.appendingPathComponent("Inbox")]
        for root in roots {
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for u in items where MediaImporter.kind(for: u) != nil { found.append(u) }
        }
        if found.isEmpty {
            if !silent { AppState.shared.showToast("No new files found") }
            return
        }
        await importFiles(found, move: true, silent: silent)
    }

    func fetchMissingCovers(_ list: [Track]) async {
        for t in list where t.artworkFile == nil && t.kind == .audio {
            let term = [t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " ")
            guard !term.isEmpty else { continue }
            let results = await OnlineServices.coverSearch(term: term, kind: .audio, limit: 10)
            if let best = OnlineServices.bestMatch(t, results), let img = await OnlineServices.image(best.full) {
                setArtwork(t.id, image: img, square: true)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func fetchLyrics(_ id: UUID) async -> Bool {
        guard let t = track(id) else { return false }
        guard let text = await OnlineServices.lyrics(title: t.title.nonEmpty ?? t.displayTitle,
                                                     artist: t.artist, album: t.album, duration: t.duration)
        else { return false }
        mutate(id) { $0.lyrics = text }
        return true
    }

    func storageUsed() -> Int64 {
        var total: Int64 = 0
        for t in tracks {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(t).path)[.size] as? NSNumber)?.int64Value ?? 0
            total += size
        }
        return total
    }
}
