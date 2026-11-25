import SwiftUI
import AVFoundation

@main
struct MJVPlayerApp: App {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var app = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Prefs.register()
        _ = EqualizerStore.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onOpenURL { app.handleOpen($0) }
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        library.saveNow()
                        player.persistState()
                    } else if phase == .active {
                        Task { await library.scanInbox(silent: true) }
                    }
                }
        }
    }
}

struct PlaylistPickerRequest: Identifiable {
    let id = UUID()
    let trackIDs: [UUID]
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    enum Tab: Hashable { case library, search, youtube, settings }

    @Published var tab: Tab = .library
    @Published var showNowPlaying = false
    @Published var editing: Track?
    @Published var coverSearch: Track?
    @Published var playlistPicker: PlaylistPickerRequest?
    @Published var pendingDelete: [Track] = []
    @Published var toast: String?
    @Published var pendingYouTubeLink: String?

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast == text { toast = nil }
        }
    }

    func confirmDelete(_ tracks: [Track]) { pendingDelete = tracks }

    func handleOpen(_ url: URL) {
        if url.isFileURL {
            Task { await LibraryStore.shared.importFiles([url]) }
        } else if YouTubeService.videoID(from: url.absoluteString) != nil {
            pendingYouTubeLink = url.absoluteString
            tab = .youtube
        }
    }
}

extension View {
    @MainActor
    func withAppEnvironment() -> some View {
        environmentObject(LibraryStore.shared)
            .environmentObject(PlayerEngine.shared)
            .environmentObject(DownloadManager.shared)
            .environmentObject(AppState.shared)
            .preferredColorScheme(.dark)
    }

    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView(selection: $app.tab) {
            NavigationStack { LibraryHomeView() }
                .miniPlayerInset()
                .tabItem { Label("Library", systemImage: "music.note.house.fill") }
                .tag(AppState.Tab.library)
            NavigationStack { SearchView() }
                .miniPlayerInset()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppState.Tab.search)
            NavigationStack { YouTubeView() }
                .miniPlayerInset()
                .tabItem { Label("YouTube", systemImage: "arrow.down.circle.fill") }
                .tag(AppState.Tab.youtube)
            NavigationStack { SettingsView() }
                .miniPlayerInset()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppState.Tab.settings)
        }
        .fullScreenCover(isPresented: $app.showNowPlaying) {
            NowPlayingView().withAppEnvironment()
        }
        .modifier(GlobalPresenters(inNowPlaying: false))
        .overlay(alignment: .top) { ToastOverlay() }
        .task { await LibraryStore.shared.scanInbox(silent: true) }
    }
}

struct ToastOverlay: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ZStack {
            if let text = app.toast {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.toast = nil }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: app.toast)
    }
}

/// Sheets that can be opened from anywhere. They are attached twice (root and Now Playing);
/// only the presenter that is currently on top shows them.
struct GlobalPresenters: ViewModifier {
    let inNowPlaying: Bool
    @EnvironmentObject var app: AppState

    private func gated<T>(_ keyPath: ReferenceWritableKeyPath<AppState, T?>) -> Binding<T?> {
        Binding(
            get: { app.showNowPlaying == inNowPlaying ? app[keyPath: keyPath] : nil },
            set: { app[keyPath: keyPath] = $0 }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: gated(\.editing)) { t in
                EditTrackView(track: t).withAppEnvironment()
            }
            .sheet(item: gated(\.coverSearch)) { t in
                NavigationStack { CoverSearchView(track: t) }.withAppEnvironment()
            }
            .sheet(item: gated(\.playlistPicker)) { req in
                PlaylistPickerSheet(request: req).withAppEnvironment()
            }
            .alert(
                app.pendingDelete.count == 1 ? "Delete \"\(app.pendingDelete[0].displayTitle)\"?" : "Delete \(app.pendingDelete.count) items?",
                isPresented: Binding(
                    get: { app.showNowPlaying == inNowPlaying && !app.pendingDelete.isEmpty },
                    set: { if !$0 { app.pendingDelete = [] } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    let ids = Set(app.pendingDelete.map(\.id))
                    app.pendingDelete = []
                    PlayerEngine.shared.remove(ids)
                    LibraryStore.shared.delete(ids)
                }
                Button("Cancel", role: .cancel) { app.pendingDelete = [] }
            } message: {
                Text("The file is removed from this device.")
            }
    }
}

// MARK: - Mini player

struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var app: AppState

    var body: some View {
        if let t = player.currentTrack {
            VStack(spacing: 0) {
                ScrubberView(compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, -8)
                HStack(spacing: 12) {
                    ArtworkView(track: t, size: 44, corner: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            if player.shuffle { Image(systemName: "shuffle") }
                            if player.repeatMode != .off { Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat") }
                            Text(t.displayArtist).lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                            .frame(width: 40, height: 44)
                    }
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 40, height: 44)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .foregroundStyle(.primary)
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { app.showNowPlaying = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 { app.showNowPlaying = true }
                else if v.translation.width < -60 { player.next() }
                else if v.translation.width > 60 { player.previous() }
            })
        }
    }
}
