import SwiftUI
import WebKit

struct YouTubeView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.videoHeight) private var preferredHeight = 1080

    @State private var link = ""
    @State private var info: YTInfo?
    @State private var loading = false
    @State private var errorText: String?
    @State private var quality = 0
    @State private var showBrowser = false

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("YouTube or YouTube Music link", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { fetch() }
                    if !link.isEmpty {
                        Button { link = ""; info = nil; errorText = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 12) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        Task { @MainActor in
                            link = s
                            fetch()
                        }
                    }
                    .buttonBorderShape(.capsule)
                    Spacer()
                    Button { showBrowser = true } label: { Label("Browse YouTube", systemImage: "safari") }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
                Button { fetch() } label: {
                    HStack {
                        Text("Get Video").fontWeight(.semibold)
                        Spacer()
                        if loading { ProgressView() }
                    }
                }
                .disabled(loading || link.trimmed.isEmpty)
            } footer: {
                Text("In the YouTube app tap Share → Copy link, then tap Paste. Or browse YouTube here, sign in with your Premium account and tap Download on any video.")
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }

            if let info {
                Section { infoCard(info) }
            }

            if !downloads.jobs.isEmpty {
                Section {
                    ForEach(downloads.jobs) { job in
                        DownloadRow(job: job)
                            .swipeActions {
                                Button { downloads.remove(job.id) } label: { Label("Remove", systemImage: "xmark") }
                                    .tint(.red)
                            }
                    }
                } header: {
                    HStack {
                        Text("Downloads")
                        Spacer()
                        if downloads.jobs.contains(where: { !$0.isActive }) {
                            Button("Clear") { downloads.clearFinished() }.font(.caption)
                        }
                    }
                } footer: {
                    Text("Keep the app open while downloading. Files are saved in Files › On My iPhone › MJV Player › Media.")
                }
            }
        }
        .navigationTitle("YouTube")
        .sheet(isPresented: $showBrowser) {
            YouTubeBrowserView { url in
                showBrowser = false
                link = url
                fetch()
            }
        }
        .onAppear(perform: consumePending)
        .onChange(of: app.pendingYouTubeLink) { _ in consumePending() }
    }

    private func consumePending() {
        guard let pending = app.pendingYouTubeLink else { return }
        app.pendingYouTubeLink = nil
        link = pending
        fetch()
    }

    @ViewBuilder private func infoCard(_ info: YTInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: info.thumbnailURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(info.title).font(.headline)
            if !info.channel.isEmpty {
                Text(info.channel).font(.subheadline).foregroundStyle(.secondary)
            }

            Button {
                downloads.start(info, audioOnly: true, option: nil)
            } label: {
                Label("Download Music (M4A)", systemImage: "music.note").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(info.audio == nil)

            if !info.videoOptions.isEmpty {
                HStack {
                    Text("Video quality")
                    Spacer()
                    Picker("Video quality", selection: $quality) {
                        ForEach(info.videoOptions) { o in Text(o.label).tag(o.height) }
                    }
                    .pickerStyle(.menu)
                }
                Button {
                    downloads.start(info, audioOnly: false, option: info.videoOptions.first { $0.height == quality })
                } label: {
                    Label("Download Video (MP4)", systemImage: "film").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
            } else {
                Label("No MP4 video stream was offered for this video, so only music can be downloaded. Turn on Settings › Backup extraction server and try again.",
                      systemImage: "film.stack")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(info.formats).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func fetch() {
        guard let id = YouTubeService.videoID(from: link) else {
            errorText = YTError.badLink.localizedDescription
            return
        }
        loading = true
        errorText = nil
        info = nil
        Task {
            do {
                let result = try await YouTubeService.fetchInfo(id: id)
                info = result
                let fitting = result.videoOptions.filter { $0.height <= preferredHeight }
                quality = (fitting.first ?? result.videoOptions.last)?.height ?? 0
            } catch {
                errorText = YouTubeService.describe(error)
            }
            loading = false
        }
    }
}

struct DownloadRow: View {
    let job: DownloadJob
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: job.thumbnailURL) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 72, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: job.audioOnly ? "music.note" : "film")
                        .font(.caption2.bold())
                        .padding(3)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(2)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.subheadline).lineLimit(1)
                status
            }
            Spacer(minLength: 4)
            action
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .waiting:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView(value: job.progress)
                Text("\(Int(job.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .processing:
            Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .done:
            Text(job.audioOnly ? "Saved to Songs" : "Saved to Videos" + (job.height.map { " · \($0)p" } ?? ""))
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    @ViewBuilder private var action: some View {
        switch job.state {
        case .waiting, .downloading, .processing:
            Button { downloads.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        case .done:
            Button {
                if let id = job.trackID, let t = library.track(id) {
                    player.play([t], context: "Downloads")
                    if t.kind == .video { app.showNowPlaying = true }
                }
            } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
        case .failed:
            Button { downloads.retry(job) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - In-app YouTube browser

@MainActor
final class WebModel: NSObject, ObservableObject {
    @Published var videoID: String?
    @Published var canGoBack = false
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    func open(_ address: String) {
        if let url = URL(string: address) { webView.load(URLRequest(url: url)) }
    }

    private func refresh() {
        canGoBack = webView.canGoBack
        guard let url = webView.url?.absoluteString else { videoID = nil; return }
        let looksLikeVideo = url.contains("watch?") || url.contains("/shorts/") || url.contains("youtu.be/")
        videoID = looksLikeVideo ? YouTubeService.videoID(from: url) : nil
    }
}

struct WebView: UIViewRepresentable {
    let model: WebModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct YouTubeBrowserView: View {
    let onDownload: (String) -> Void
    @StateObject private var model = WebModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(model: model)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    if let id = model.videoID {
                        Button {
                            model.webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())", completionHandler: nil)
                            onDownload("https://www.youtube.com/watch?v=\(id)")
                        } label: {
                            Label("Download this video", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 13)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        }
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(), value: model.videoID)
                .navigationTitle("YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { model.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!model.canGoBack)
                        Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        Menu {
                            Button("YouTube") { model.open("https://m.youtube.com") }
                            Button("YouTube Music") { model.open("https://music.youtube.com") }
                        } label: { Image(systemName: "house") }
                    }
                }
        }
        .onAppear { if model.webView.url == nil { model.open("https://m.youtube.com") } }
    }
}
