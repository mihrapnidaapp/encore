import SwiftUI
import PhotosUI

struct EditTrackView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Track
    @State private var photoItem: PhotosPickerItem?
    @State private var newCover: UIImage?
    @State private var removeCover = false
    @State private var lyricsStatus: String?
    @State private var fetchingLyrics = false

    init(track: Track) { _draft = State(initialValue: track) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        coverPreview
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    NavigationLink {
                        CoverSearchView(track: draft) { img in
                            newCover = img
                            removeCover = false
                        }
                    } label: {
                        Label(draft.kind == .video ? "Search Poster Online" : "Search Cover Online", systemImage: "magnifyingglass")
                    }
                    if draft.kind == .video {
                        Button {
                            Task {
                                let at = player.currentTrack?.id == draft.id ? player.clock.time : nil
                                if let img = await MediaImporter.videoFrame(library.fileURL(draft), duration: draft.duration, at: at) {
                                    newCover = img
                                    removeCover = false
                                }
                            }
                        } label: {
                            Label("Use Frame from Video", systemImage: "film")
                        }
                    }
                    if draft.artworkFile != nil || newCover != nil {
                        Button(role: .destructive) { newCover = nil; removeCover = true } label: {
                            Label("Remove Cover", systemImage: "trash")
                        }
                    }
                }

                Section("Details") {
                    field("Title", $draft.title)
                    field("Artist", $draft.artist)
                    field("Album", $draft.album)
                    field("Genre", $draft.genre)
                    field("Year", $draft.year)
                    HStack {
                        Text("Track #").foregroundStyle(.secondary)
                        TextField("", text: Binding(
                            get: { draft.trackNumber.map(String.init) ?? "" },
                            set: { draft.trackNumber = Int($0.trimmed) }
                        ))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    TextEditor(text: Binding(get: { draft.lyrics ?? "" }, set: { draft.lyrics = $0.isEmpty ? nil : $0 }))
                        .frame(minHeight: 160)
                        .font(.callout)
                    Button {
                        searchLyrics()
                    } label: {
                        HStack {
                            Label("Search Lyrics Online", systemImage: "quote.bubble")
                            Spacer()
                            if fetchingLyrics { ProgressView() }
                        }
                    }
                    .disabled(fetchingLyrics)
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text(lyricsStatus ?? "Plain text or synced LRC ([mm:ss.xx] line). Synced lyrics scroll with the song.")
                }

                if let notes = draft.notes, !notes.isEmpty {
                    Section("Description") {
                        Text(notes).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                Section("File") {
                    LabeledContent("Name", value: draft.fileName)
                    LabeledContent("Length", value: formatTime(draft.duration))
                    LabeledContent("Plays", value: "\(draft.playCount)")
                    LabeledContent("Added", value: draft.dateAdded.formatted(date: .abbreviated, time: .shortened))
                    if let s = draft.sourceURL, let u = URL(string: s) {
                        Link(destination: u) { Label("Open on YouTube", systemImage: "play.rectangle") }
                    }
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold) }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        newCover = img
                        removeCover = false
                    }
                }
            }
        }
    }

    @ViewBuilder private var coverPreview: some View {
        let size: CGFloat = 160
        if let newCover {
            Image(uiImage: newCover)
                .resizable()
                .scaledToFill()
                .frame(width: draft.kind == .video ? size * 16 / 9 : size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if removeCover {
            ArtworkView(track: nil, size: size, corner: 10)
        } else if draft.kind == .video {
            ArtworkView(track: draft, size: size * 16 / 9, corner: 10, aspect: 16 / 9)
        } else {
            ArtworkView(track: draft, size: size, corner: 10)
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: text).multilineTextAlignment(.trailing)
        }
    }

    private func searchLyrics() {
        fetchingLyrics = true
        lyricsStatus = nil
        Task {
            if let text = await OnlineServices.lyrics(title: draft.title.nonEmpty ?? draft.displayTitle,
                                                      artist: draft.artist, album: draft.album, duration: draft.duration) {
                draft.lyrics = text
                lyricsStatus = "Lyrics found. Tap Save to keep them."
            } else {
                lyricsStatus = "No lyrics found. Check the title and artist, or paste them above."
            }
            fetchingLyrics = false
        }
    }

    private func save() {
        library.update(draft)
        if let newCover {
            library.setArtwork(draft.id, image: newCover, square: draft.kind == .audio)
        } else if removeCover {
            library.removeArtwork(draft.id)
        }
        player.refreshNowPlaying(draft.id)
        dismiss()
    }
}

struct CoverSearchView: View {
    let track: Track
    var onPick: ((UIImage) -> Void)?
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var results: [CoverResult] = []
    @State private var status = "Searching…"
    @State private var busy = false

    init(track: Track, onPick: ((UIImage) -> Void)? = nil) {
        self.track = track
        self.onPick = onPick
        _term = State(initialValue: [track.artist, track.title.nonEmpty ?? track.displayTitle].filter { !$0.isEmpty }.joined(separator: " "))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Search", text: $term)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button("Search") { search() }.buttonStyle(.borderedProminent)
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 12) {
                    ForEach(results) { r in
                        Button { pick(r) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        AsyncImage(url: r.thumb) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(r.album.isEmpty ? r.title : r.album).font(.caption2).lineLimit(1)
                                Text(r.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(track.kind == .video ? "Find Poster" : "Find Cover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if onPick == nil { Button("Close") { dismiss() } }
            }
        }
        .task { search() }
    }

    private func search() {
        let q = term.trimmed
        guard !q.isEmpty else { return }
        status = "Searching…"
        Task {
            results = await OnlineServices.coverSearch(term: q, kind: track.kind, limit: 30)
            status = results.isEmpty ? "No results. Try a different search." : "Tap a cover to use it."
        }
    }

    private func pick(_ r: CoverResult) {
        busy = true
        status = "Downloading…"
        Task {
            defer { busy = false }
            var downloaded = await OnlineServices.image(r.full)
            if downloaded == nil { downloaded = await OnlineServices.image(r.thumb) }
            guard let img = downloaded else {
                status = "Could not download this image."
                return
            }
            if let onPick {
                onPick(img)
            } else {
                library.setArtwork(track.id, image: img, square: track.kind == .audio)
                app.showToast("Cover saved")
            }
            dismiss()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @AppStorage(Prefs.autoCovers) private var autoCovers = true
    @AppStorage(Prefs.autoLyrics) private var autoLyrics = true
    @AppStorage(Prefs.cleanTitles) private var cleanTitles = true
    @AppStorage(Prefs.remoteFallback) private var remoteFallback = true
    @AppStorage(Prefs.videoHeight) private var videoHeight = 1080
    @AppStorage(Prefs.resumeLong) private var resumeLong = true
    @State private var storage = "…"
    @State private var fetchingCovers = false
    @State private var showSound = false
    @ObservedObject private var eq = EqualizerStore.shared
    @AppStorage(Prefs.crossfade) private var crossfade = 0.0

    var body: some View {
        Form {
            Section {
                Toggle("Find missing covers online", isOn: $autoCovers)
                Toggle("Find lyrics automatically", isOn: $autoLyrics)
                Toggle("Resume long tracks and videos", isOn: $resumeLong)
                Button {
                    fetchingCovers = true
                    Task {
                        await library.fetchMissingCovers(library.tracks)
                        fetchingCovers = false
                    }
                } label: {
                    HStack {
                        Text("Find Covers for Whole Library")
                        Spacer()
                        if fetchingCovers { ProgressView() }
                    }
                }
                .disabled(fetchingCovers)
                Button("Import Files from App Folder") { Task { await library.scanInbox(silent: false) } }
            } header: {
                Text("Library")
            } footer: {
                Text("Covers come from the iTunes Search API, lyrics from LRCLIB. Files you copy into On My iPhone › Encore are imported automatically.")
            }

            Section {
                Button { showSound = true } label: {
                    LabeledContent("Equalizer", value: eq.enabled ? eq.presetName : "Off")
                }
                Button { showSound = true } label: {
                    LabeledContent("Crossfade", value: crossfade == 0 ? "Off" : "\(Int(crossfade)) s")
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Lock screen, Control Center, AirPods and the car's Now Playing screen (CarPlay or Bluetooth) show the cover and control playback.")
            }

            Section {
                Toggle("Clean up video titles", isOn: $cleanTitles)
                Picker("Preferred video quality", selection: $videoHeight) {
                    ForEach([360, 480, 720, 1080], id: \.self) { Text("\($0)p").tag($0) }
                }
                Toggle("Backup extraction server", isOn: $remoteFallback)
            } header: {
                Text("YouTube")
            } footer: {
                Text("Clean up turns \"Artist - Song (Official Video)\" into artist and title. When YouTube changes something and links stop working on the phone, the backup server (youtubekit.dev) finds the stream links instead; only the video ID is sent.")
            }

            Section("Storage") {
                LabeledContent("Songs", value: "\(library.songs.count)")
                LabeledContent("Videos", value: "\(library.videos.count)")
                LabeledContent("Playlists", value: "\(library.playlists.count)")
                LabeledContent("Space used", value: storage)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Text("Encore plays music and videos stored on this device. YouTube downloads are for your own offline use.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showSound) { EqualizerView().withAppEnvironment() }
        .onAppear {
            storage = ByteCountFormatter.string(fromByteCount: library.storageUsed(), countStyle: .file)
        }
    }
}
