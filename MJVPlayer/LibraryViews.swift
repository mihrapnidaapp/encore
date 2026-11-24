import SwiftUI
import UniformTypeIdentifiers

struct LibraryHomeView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState
    @State private var showImporter = false

    var body: some View {
        let recent = Array(TrackSort.added.apply(library.tracks).prefix(15))
        List {
            Section {
                NavigationLink { PlaylistsView() } label: { row("Playlists", "music.note.list", library.playlists.count) }
                NavigationLink { ArtistsView() } label: { row("Artists", "music.mic", nil) }
                NavigationLink { AlbumsView() } label: { row("Albums", "square.stack", nil) }
                NavigationLink { TracksView(title: "Songs", tracks: library.songs) } label: {
                    row("Songs", "music.note", library.songs.count)
                }
                NavigationLink { VideosView() } label: { row("Videos", "film", library.videos.count) }
                NavigationLink { TracksView(title: "Favorites", tracks: library.tracks.filter(\.favorite), defaultSort: .added) } label: {
                    row("Favorites", "heart", nil)
                }
                NavigationLink {
                    TracksView(title: "Recently Played", tracks: library.tracks.filter { $0.lastPlayed != nil }, defaultSort: .played)
                } label: { row("Recently Played", "clock.arrow.circlepath", nil) }
                NavigationLink {
                    TracksView(title: "Most Played", tracks: library.tracks.filter { $0.playCount > 0 }, defaultSort: .plays)
                } label: { row("Most Played", "chart.bar", nil) }
                NavigationLink {
                    TracksView(title: "From YouTube", tracks: library.tracks.filter(\.isFromYouTube), defaultSort: .added)
                } label: { row("From YouTube", "play.rectangle", nil) }
            }

            if library.tracks.isEmpty {
                Section {
                    EmptyStateView(icon: "music.note.house", title: "Your library is empty",
                                   message: "Tap + to import music and videos from the Files app, or download from YouTube.")
                    Button { showImporter = true } label: { Label("Import Files", systemImage: "folder") }
                    Button { app.tab = .youtube } label: { Label("Download from YouTube", systemImage: "arrow.down.circle") }
                }
            } else {
                Section("Recently Added") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array(recent.enumerated()), id: \.element.id) { i, t in
                                Button {
                                    player.play(recent, startAt: i, context: "Recently Added")
                                    if t.kind == .video { app.showNowPlaying = true }
                                } label: {
                                    AlbumTile(title: t.displayTitle, subtitle: t.displayArtist, cover: t)
                                        .frame(width: 140)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenuItems(track: t) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showImporter = true } label: { Label("Import Files…", systemImage: "folder") }
                    Button { Task { await library.scanInbox(silent: false) } } label: {
                        Label("Scan App Folder", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .image, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .overlay(alignment: .bottom) {
            if library.importing {
                HStack(spacing: 8) { ProgressView(); Text("Importing…") }
                    .padding(12)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }

    private func row(_ title: String, _ icon: String, _ count: Int?) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
            }
            Spacer()
            if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary) }
        }
        .font(.title3)
        .padding(.vertical, 2)
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @EnvironmentObject var library: LibraryStore
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        let albums = library.albums
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(albums) { a in
                    NavigationLink { AlbumDetailView(albumID: a.id) } label: {
                        AlbumTile(title: a.name, subtitle: a.artist, cover: a.cover)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .overlay {
            if albums.isEmpty {
                EmptyStateView(icon: "square.stack", title: "No albums",
                               message: "Albums appear when songs have an album name. You can set it with Edit Info.")
            }
        }
        .navigationTitle("Albums")
    }
}

struct AlbumDetailView: View {
    let albumID: String
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        if let album = library.album(albumID) {
            List {
                VStack(spacing: 8) {
                    ArtworkView(track: album.cover, size: 220, corner: 10)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                    Text(album.name).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                    let total = album.tracks.reduce(0) { $0 + $1.duration }
                    Text([album.year.nonEmpty, "\(album.tracks.count) songs", formatTime(total)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    PlayShuffleButtons(tracks: album.tracks, context: album.name).padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                    Button { player.play(album.tracks, startAt: i, context: album.name) } label: {
                        TrackRow(track: t, number: t.trackNumber ?? (i + 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenuItems(track: t) }
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(icon: "square.stack", title: "Album not found", message: "")
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var query = ""

    var body: some View {
        let artists = library.artists.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        List(artists) { a in
            NavigationLink {
                TracksView(title: a.name, tracks: a.tracks, defaultSort: .album)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: a.cover, size: 52, corner: 26)
                    VStack(alignment: .leading) {
                        Text(a.name).font(.body.weight(.medium))
                        Text("\(a.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Artists")
        .navigationTitle("Artists")
    }
}

// MARK: - Videos

struct VideosView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState
    @State private var sort: TrackSort = .added
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        let videos = sort.apply(library.videos)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(Array(videos.enumerated()), id: \.element.id) { i, t in
                    Button {
                        player.play(videos, startAt: i, context: "Videos")
                        app.showNowPlaying = true
                    } label: {
                        VideoTile(track: t)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenuItems(track: t) }
                }
            }
            .padding(16)
        }
        .overlay {
            if videos.isEmpty {
                EmptyStateView(icon: "film", title: "No videos", message: "Import videos or download them from YouTube.")
            }
        }
        .navigationTitle("Videos")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach([TrackSort.added, .title, .played, .duration]) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        List {
            Button { newName = ""; creating = true } label: {
                Label("New Playlist", systemImage: "plus")
            }
            ForEach(library.playlists) { p in
                NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                    HStack(spacing: 12) {
                        ArtworkView(track: library.tracks(in: p).first, size: 56, corner: 6)
                        VStack(alignment: .leading) {
                            Text(p.name).font(.body.weight(.medium))
                            Text("\(p.trackIDs.count) items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { library.deletePlaylists(at: $0) }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(newName) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState
    @State private var showAdd = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let pl = library.playlist(playlistID) {
            let items = library.tracks(in: pl)
            List {
                VStack(spacing: 8) {
                    ArtworkView(track: items.first, size: 180, corner: 10)
                    Text(pl.name).font(.title2.bold())
                    Text("\(items.count) items · \(formatTime(items.reduce(0) { $0 + $1.duration }))")
                        .font(.caption).foregroundStyle(.secondary)
                    PlayShuffleButtons(tracks: items, context: pl.name).padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)

                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    Button {
                        player.play(items, startAt: i, context: pl.name)
                        if t.kind == .video { app.showNowPlaying = true }
                    } label: {
                        TrackRow(track: t)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        TrackMenuItems(track: t)
                        Button(role: .destructive) { library.removeFromPlaylist(pl.id, at: IndexSet(integer: i)) } label: {
                            Label("Remove from Playlist", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove { library.movePlaylistTracks(pl.id, from: $0, to: $1) }
                .onDelete { library.removeFromPlaylist(pl.id, at: $0) }
            }
            .listStyle(.plain)
            .navigationTitle(pl.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    EditButton()
                    Menu {
                        Button { showAdd = true } label: { Label("Add Items", systemImage: "plus") }
                        Button { newName = pl.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTracksSheet(playlistID: pl.id).withAppEnvironment() }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { library.renamePlaylist(pl.id, newName) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            EmptyStateView(icon: "music.note.list", title: "Playlist not found", message: "")
        }
    }
}

struct AddTracksSheet: View {
    let playlistID: UUID
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var query = ""

    var body: some View {
        let list = TrackSort.title.apply(library.tracks.filter { $0.matches(query) })
        NavigationStack {
            List(list, selection: $selection) { t in
                TrackRow(track: t)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query)
            .navigationTitle("Add Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selection.count)") {
                        let ordered = list.map(\.id).filter { selection.contains($0) }
                        library.addToPlaylist(playlistID, ordered)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}

struct PlaylistPickerSheet: View {
    let request: PlaylistPickerRequest
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { newName = ""; creating = true } label: { Label("New Playlist…", systemImage: "plus") }
                ForEach(library.playlists) { p in
                    Button {
                        library.addToPlaylist(p.id, request.trackIDs)
                        app.showToast("Added to \(p.name)")
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(track: library.tracks(in: p).first, size: 44, corner: 6)
                            Text(p.name)
                            Spacer()
                            Text("\(p.trackIDs.count)").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let p = library.createPlaylist(newName, trackIDs: request.trackIDs)
                    app.showToast("Added to \(p.name)")
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState
    @State private var query = ""

    var body: some View {
        let q = query.trimmed
        List {
            if q.isEmpty {
                Section {
                    Text("Search your songs, videos, albums, artists and playlists.")
                        .foregroundStyle(.secondary)
                }
            } else {
                let songs = TrackSort.title.apply(library.songs.filter { $0.matches(q) })
                let videos = library.videos.filter { $0.matches(q) }
                let albums = library.albums.filter { $0.name.localizedStandardContains(q) || $0.artist.localizedStandardContains(q) }
                let artists = library.artists.filter { $0.name.localizedStandardContains(q) }
                let playlists = library.playlists.filter { $0.name.localizedStandardContains(q) }

                if !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists.prefix(6)) { a in
                            NavigationLink { TracksView(title: a.name, tracks: a.tracks, defaultSort: .album) } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(track: a.cover, size: 40, corner: 20)
                                    Text(a.name)
                                }
                            }
                        }
                    }
                }
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums.prefix(6)) { a in
                            NavigationLink { AlbumDetailView(albumID: a.id) } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(track: a.cover, size: 44, corner: 6)
                                    VStack(alignment: .leading) {
                                        Text(a.name)
                                        Text(a.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !songs.isEmpty {
                    Section("Songs") {
                        ForEach(Array(songs.prefix(60).enumerated()), id: \.element.id) { i, t in
                            Button { player.play(songs, startAt: i, context: "Search") } label: { TrackRow(track: t) }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenuItems(track: t) }
                        }
                    }
                }
                if !videos.isEmpty {
                    Section("Videos") {
                        ForEach(Array(videos.prefix(30).enumerated()), id: \.element.id) { i, t in
                            Button {
                                player.play(videos, startAt: i, context: "Search")
                                app.showNowPlaying = true
                            } label: { TrackRow(track: t) }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenuItems(track: t) }
                        }
                    }
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { p in
                            NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                                Label(p.name, systemImage: "music.note.list")
                            }
                        }
                    }
                }
                if songs.isEmpty && videos.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty {
                    Text("No results for \"\(q)\"").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
    }
}
