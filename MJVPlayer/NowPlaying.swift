import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var app: AppState
    @ObservedObject private var eq = EqualizerStore.shared
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showSound = false
    @State private var skipFlash: String?
    @State private var background: UIImage?

    var body: some View {
        ZStack {
            backdrop
            if let t = player.currentTrack {
                VStack(spacing: 0) {
                    header(t)
                    Spacer(minLength: 6)
                    stage(t)
                    Spacer(minLength: 10)
                    titleRow(t).padding(.horizontal, 24)
                    ScrubberView().padding(.top, 10)
                    controls(t).padding(.top, 2)
                    PlaybackModesBar().padding(.horizontal, 24).padding(.top, 6)
                    VolumeRow().padding(.horizontal, 24).padding(.top, 8)
                    bottomBar(t).padding(.top, 12)
                }
                .padding(.bottom, 12)
            } else {
                VStack(spacing: 16) {
                    Text("Nothing is playing").font(.title3)
                    Button("Close") { app.showNowPlaying = false }
                }
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: player.currentTrack?.artworkFile) {
            if let f = player.currentTrack?.artworkFile { background = await ArtworkCache.shared.image(f) } else { background = nil }
        }
        .sheet(isPresented: $showQueue) { QueueView().withAppEnvironment() }
        .sheet(isPresented: $showSound) { EqualizerView().withAppEnvironment() }
        .modifier(GlobalPresenters(inNowPlaying: true))
        .overlay(alignment: .top) { ToastOverlay() }
    }

    // MARK: Pieces

    private var backdrop: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
            if let background {
                Image(uiImage: background)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .opacity(0.85)
            }
            LinearGradient(colors: [Color.black.opacity(0.15), Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: background)
    }

    private func header(_ t: Track) -> some View {
        HStack {
            Button { app.showNowPlaying = false } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("PLAYING FROM").font(.caption2).foregroundStyle(Color.white.opacity(0.6))
                Text(player.contextTitle.isEmpty ? "Library" : player.contextTitle)
                    .font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Menu {
                Menu {
                    RepeatChoices()
                } label: {
                    Label("Repeat: " + (player.repeatMode == .off ? "Off" : player.repeatMode == .all ? "All" : "This Song"),
                          systemImage: player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                Divider()
                Button { app.playlistPicker = PlaylistPickerRequest(trackIDs: [t.id]) } label: {
                    Label("Add to Playlist…", systemImage: "music.note.list")
                }
                Button { app.editing = t } label: { Label("Edit Info & Lyrics", systemImage: "pencil") }
                Button { app.coverSearch = t } label: {
                    Label(t.kind == .video ? "Find Poster" : "Find Cover", systemImage: "photo")
                }
                ShareLink(item: library.fileURL(t)) { Label("Share File", systemImage: "square.and.arrow.up") }
                if let s = t.sourceURL, let u = URL(string: s) {
                    Link(destination: u) { Label("Open on YouTube", systemImage: "play.rectangle") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func stage(_ t: Track) -> some View {
        if t.kind == .video {
            VideoSurface(player: player.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
        } else if showLyrics {
            LyricsPanel(track: t)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ArtworkView(track: t, size: nil, corner: 14)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                .padding(.horizontal, 28)
                .overlay {
                    // Double-tap the left or right side to jump 10 seconds, the middle to favorite.
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) { jump(-10) }
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                flash(t.favorite ? "heart.slash.fill" : "heart.fill")
                                library.toggleFavorite(t.id)
                            }
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) { jump(10) }
                    }
                }
                .overlay {
                    if let skipFlash {
                        Image(systemName: skipFlash)
                            .font(.system(size: 44, weight: .semibold))
                            .padding(22)
                            .background(.ultraThinMaterial, in: Circle())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.height > 80 { app.showNowPlaying = false }
                    else if v.translation.width < -60 { player.next() }
                    else if v.translation.width > 60 { player.previous() }
                })
        }
    }

    private func jump(_ seconds: Double) {
        player.skip(by: seconds)
        flash(seconds < 0 ? "gobackward.10" : "goforward.10")
    }

    private func flash(_ symbol: String) {
        haptic()
        withAnimation(.easeOut(duration: 0.15)) { skipFlash = symbol }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if skipFlash == symbol { withAnimation(.easeIn(duration: 0.25)) { skipFlash = nil } }
        }
    }

    private func titleRow(_ t: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.displayTitle).font(.title3.bold()).lineLimit(1)
                Text(t.displayArtist).font(.body).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            Button { library.toggleFavorite(t.id) } label: {
                Image(systemName: t.favorite ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(t.favorite ? Color.brand : Color.white.opacity(0.8))
            }
        }
    }

    private func controls(_ t: Track) -> some View {
        HStack {
            Spacer()
            if t.kind == .video {
                Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Spacer()
            }
            Button { haptic(); player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
            Spacer()
            Button { haptic(); player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
                    .symbolRenderingMode(.hierarchical)
            }
            Spacer()
            Button { haptic(); player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
            Spacer()
            if t.kind == .video {
                Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title2) }
                Spacer()
            }
        }
        .padding(.horizontal, 28)
    }

    private func bottomBar(_ t: Track) -> some View {
        HStack {
            if t.kind == .audio {
                Button { withAnimation(.easeInOut) { showLyrics.toggle() } } label: {
                    Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble").font(.title3)
                }
            } else {
                Image(systemName: "quote.bubble").font(.title3).opacity(0)
            }
            Spacer()
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                    Button { player.setRate(Float(r)) } label: {
                        if abs(Double(player.rate) - r) < 0.01 {
                            Label(speedText(r), systemImage: "checkmark")
                        } else {
                            Text(speedText(r))
                        }
                    }
                }
            } label: {
                Text(speedText(Double(player.rate)))
                    .font(.subheadline.weight(.bold))
                    .frame(minWidth: 44)
            }
            Spacer()
            AirPlayButton().frame(width: 36, height: 36)
            Spacer()
            Menu {
                if player.sleepEnd != nil || player.sleepAfterTrack {
                    Button(role: .destructive) { player.setSleepTimer(minutes: nil) } label: {
                        Label("Turn Off Timer", systemImage: "xmark")
                    }
                }
                ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
                }
                Button("End of Current Track") { player.sleepAtEndOfTrack() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (player.sleepEnd != nil || player.sleepAfterTrack) ? "moon.zzz.fill" : "moon.zzz")
                        .font(.title3)
                    if let end = player.sleepEnd {
                        Text(end, style: .timer).font(.caption.monospacedDigit())
                    }
                }
            }
            Spacer()
            Button { haptic(); player.cycleLoop() } label: {
                Text(player.loopA != nil && player.loopB == nil ? "A–" : "A-B")
                    .font(.footnote.weight(.heavy))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
                    .foregroundStyle(player.loopA != nil ? Color.brand : Color.white)
            }
            Spacer()
            Button { showSound = true } label: {
                Image(systemName: "slider.vertical.3").font(.title3)
                    .foregroundStyle(eq.enabled ? Color.brand : Color.white)
            }
            Spacer()
            Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.title3) }
        }
        .padding(.horizontal, 22)
    }

    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    private func speedText(_ r: Double) -> String {
        r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }
}

// MARK: - Scrubber

/// Drag anywhere on the bar to move through the song. The position is read straight from the
/// player several times a second, so the bar moves on its own while the song plays.
struct ScrubberView: View {
    var compact = false
    @EnvironmentObject var player: PlayerEngine
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let dur = player.duration
            let shown = dragFraction.map { $0 * dur } ?? player.position
            let frac = dur > 0 ? min(max(shown / dur, 0), 1) : 0
            VStack(spacing: compact ? 0 : 2) {
                bar(frac: frac, duration: dur)
                if !compact {
                    HStack {
                        Text(formatTime(shown))
                        Spacer()
                        Text("-" + formatTime(max(dur - shown, 0)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(dragFraction != nil ? Color.white : Color.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, compact ? 0 : 24)
    }

    private func bar(frac: Double, duration dur: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dragging = dragFraction != nil
            let thickness: CGFloat = compact ? (dragging ? 6 : 3) : (dragging ? 12 : 6)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(compact ? Color.primary.opacity(0.15) : Color.white.opacity(0.22))
                    .frame(width: w, height: thickness)
                if let a = player.loopA, dur > 0 {
                    let b = player.loopB ?? a
                    Rectangle()
                        .fill(Color.brand.opacity(0.5))
                        .frame(width: max(w * (b - a) / dur, 2), height: thickness + 6)
                        .offset(x: w * a / dur)
                }
                Capsule()
                    .fill(compact ? Color.brand : Color.white)
                    .frame(width: max(w * frac, thickness), height: thickness)
                if !compact {
                    Circle()
                        .fill(Color.white)
                        .frame(width: dragging ? 22 : 14, height: dragging ? 22 : 14)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: w * frac - (dragging ? 11 : 7))
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragFraction == nil { UISelectionFeedbackGenerator().selectionChanged() }
                        dragFraction = min(max(g.location.x / max(w, 1), 0), 1)
                    }
                    .onEnded { g in
                        let f = min(max(g.location.x / max(w, 1), 0), 1)
                        if dur > 0 { player.seek(to: f * dur) }
                        dragFraction = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: compact ? 18 : 34)
    }
}

// MARK: - Volume

struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(Color.white.opacity(0.6))
            SystemVolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(Color.white.opacity(0.6))
        }
    }
}

/// The phone's own volume slider; it also follows the hardware volume buttons.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Lyrics

struct LyricsPanel: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState
    @State private var loading = false
    @State private var notFound = false

    var body: some View {
        let lines = LRC.parse(track.lyrics ?? "")
        Group {
            if lines.isEmpty {
                VStack(spacing: 14) {
                    if loading {
                        ProgressView().tint(.white)
                        Text("Looking for lyrics…").foregroundStyle(Color.white.opacity(0.7))
                    } else {
                        Image(systemName: "quote.bubble").font(.largeTitle).foregroundStyle(Color.white.opacity(0.6))
                        Text(notFound ? "No lyrics found." : "No lyrics yet.").foregroundStyle(Color.white.opacity(0.7))
                        HStack {
                            Button("Search Online") { search() }
                            Button("Add Manually") { app.editing = track }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                LyricsScroller(lines: lines, clock: player.clock)
            }
        }
        .task(id: track.id) {
            notFound = false
            if (track.lyrics ?? "").isEmpty, Prefs.bool(Prefs.autoLyrics) { search() }
        }
    }

    private func search() {
        guard !loading else { return }
        loading = true
        Task {
            let ok = await library.fetchLyrics(track.id)
            notFound = !ok
            loading = false
        }
    }
}

struct LyricsScroller: View {
    let lines: [LyricLine]
    @ObservedObject var clock: PlaybackClock
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        let current = LRC.currentIndex(lines, time: clock.time)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title2.bold())
                            .foregroundStyle(lineColor(line, current: current))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            .onTapGesture { if let t = line.time { player.seek(to: t) } }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 120)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                        .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: current) { idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    private func lineColor(_ line: LyricLine, current: Int?) -> Color {
        guard line.time != nil else { return Color.white.opacity(0.9) }
        return line.id == current ? Color.white : Color.white.opacity(0.35)
    }
}

// MARK: - Queue

struct QueueView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let upcoming = player.upcoming
        NavigationStack {
            List {
                if let cur = player.currentTrack {
                    Section("Now Playing") { TrackRow(track: cur) }
                }
                Section {
                    ForEach(Array(upcoming.enumerated()), id: \.offset) { i, t in
                        Button { player.jumpToUpcoming(i) } label: { TrackRow(track: t) }
                            .buttonStyle(.plain)
                    }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                    .onDelete { player.removeUpcoming(at: $0) }
                } header: {
                    Text(player.contextTitle.isEmpty ? "Up Next" : "Up Next · from \(player.contextTitle)")
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) { player.clearUpcoming() } label: {
                            Label("Clear Up Next", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Video and AirPlay

struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.delegate = context.coordinator
        context.coordinator.attach(vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.player = player
        if !context.coordinator.detached, vc.player !== player { vc.player = player }
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    /// When the app goes to the background without Picture in Picture, the video layer is detached
    /// so the sound keeps playing.
    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var player: AVPlayer
        weak var vc: AVPlayerViewController?
        var pipActive = false
        var detached = false
        private var tokens: [NSObjectProtocol] = []

        init(player: AVPlayer) { self.player = player }

        func attach(_ vc: AVPlayerViewController) {
            self.vc = vc
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enteredBackground() }
            })
            tokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enteringForeground() }
            })
        }

        private func enteredBackground() {
            guard !pipActive, let vc else { return }
            vc.player = nil
            detached = true
        }

        private func enteringForeground() {
            guard detached else { return }
            vc?.player = player
            detached = false
        }

        nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in self.pipActive = true }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in self.pipActive = false }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in AppState.shared.showNowPlaying = true }
            completionHandler(true)
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(red: 1, green: 0.23, blue: 0.36, alpha: 1)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
