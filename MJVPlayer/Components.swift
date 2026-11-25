import SwiftUI

extension Color {
    /// The app's pink. Used instead of the accent color on screens that tint everything white,
    /// where `Color.accentColor` would also turn white.
    static let brand = Color(red: 1, green: 0.231, blue: 0.361)
}

// MARK: - Artwork

struct ArtworkView: View {
    let track: Track?
    var size: CGFloat? = nil
    var corner: CGFloat = 6
    var aspect: CGFloat = 1
    @State private var image: UIImage?

    init(track: Track?, size: CGFloat? = nil, corner: CGFloat = 6, aspect: CGFloat = 1) {
        self.track = track
        self.size = size
        self.corner = corner
        self.aspect = aspect
        _image = State(initialValue: track?.artworkFile.flatMap { ArtworkCache.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let size {
                content.frame(width: size, height: size / aspect)
            } else {
                Color.clear.aspectRatio(aspect, contentMode: .fit).overlay(content)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: track?.artworkFile) {
            guard let file = track?.artworkFile else { image = nil; return }
            image = await ArtworkCache.shared.image(file)
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geo in
                    Image(systemName: track?.kind == .video ? "film" : "music.note")
                        .font(.system(size: min(geo.size.width, geo.size.height) * 0.4, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    private var placeholderColors: [Color] {
        let seed = (track?.displayTitle ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.55), Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.35)]
    }
}

// MARK: - Rows and tiles

struct TrackRow: View {
    let track: Track
    var number: Int? = nil
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        let isCurrent = player.currentTrack?.id == track.id
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
            } else {
                ArtworkView(track: track, size: 48, corner: 6, aspect: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                HStack(spacing: 4) {
                    if track.kind == .video { Image(systemName: "film").font(.caption2) }
                    if track.isFromYouTube { Image(systemName: "play.rectangle.fill").font(.caption2) }
                    Text(track.subtitle).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if track.favorite {
                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Color.accentColor)
            }
            Text(formatTime(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct VideoTile: View {
    let track: Track
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: track, size: nil, corner: 10, aspect: 16 / 9)
                .overlay(alignment: .bottomTrailing) {
                    Text(formatTime(track.duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            Text(track.displayTitle).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct AlbumTile: View {
    let title: String
    let subtitle: String
    let cover: Track?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(track: cover, size: nil, corner: 8)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Actions

struct TrackMenuItems: View {
    let track: Track
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var app: AppState

    var body: some View {
        Button { player.playNext([track.id]); app.showToast("Playing next") } label: {
            Label("Play Next", systemImage: "text.insert")
        }
        Button { player.addToQueue([track.id]); app.showToast("Added to queue") } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        Button { app.playlistPicker = PlaylistPickerRequest(trackIDs: [track.id]) } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }
        Button { library.toggleFavorite(track.id) } label: {
            Label(track.favorite ? "Remove Favorite" : "Favorite", systemImage: track.favorite ? "heart.slash" : "heart")
        }
        Divider()
        Button { app.editing = track } label: { Label("Edit Info", systemImage: "pencil") }
        Button { app.coverSearch = track } label: {
            Label(track.kind == .video ? "Find Poster" : "Find Cover", systemImage: "photo")
        }
        ShareLink(item: library.fileURL(track)) { Label("Share File", systemImage: "square.and.arrow.up") }
        if let s = track.sourceURL, let u = URL(string: s) {
            Link(destination: u) { Label("Open on YouTube", systemImage: "play.rectangle") }
        }
        Divider()
        Button(role: .destructive) { app.confirmDelete([track]) } label: { Label("Delete", systemImage: "trash") }
    }
}

struct PlayShuffleButtons: View {
    let tracks: [Track]
    let context: String
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks, context: context)
                if tracks.first?.kind == .video { app.showNowPlaying = true }
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button {
                player.play(tracks, shuffled: true, context: context)
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .font(.headline)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(Color.accentColor)
        .disabled(tracks.isEmpty)
    }
}

/// A playable list of tracks with filter and sort.
struct TracksView: View {
    let title: String
    let tracks: [Track]
    var showSort = true
    @State private var sort: TrackSort
    @State private var query = ""
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState

    init(title: String, tracks: [Track], defaultSort: TrackSort = .title, showSort: Bool = true) {
        self.title = title
        self.tracks = tracks
        self.showSort = showSort
        _sort = State(initialValue: defaultSort)
    }

    var body: some View {
        let list = sort.apply(query.isEmpty ? tracks : tracks.filter { $0.matches(query) })
        List {
            if !tracks.isEmpty {
                PlayShuffleButtons(tracks: list, context: title)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                Button {
                    player.play(list, startAt: i, context: title)
                    if t.kind == .video { app.showNowPlaying = true }
                } label: {
                    TrackRow(track: t)
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenuItems(track: t) }
                .swipeActions(edge: .leading) {
                    Button { player.playNext([t.id]); app.showToast("Playing next") } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    .tint(.orange)
                    Button { player.addToQueue([t.id]); app.showToast("Added to queue") } label: {
                        Label("Queue", systemImage: "text.append")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button { app.confirmDelete([t]) } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                    Button { app.playlistPicker = PlaylistPickerRequest(trackIDs: [t.id]) } label: {
                        Label("Playlist", systemImage: "music.note.list")
                    }
                    .tint(.purple)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if tracks.isEmpty {
                EmptyStateView(icon: "music.note", title: "Nothing here yet",
                               message: "Import files from the Library tab or download from YouTube.")
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if showSort {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TrackSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }
}
