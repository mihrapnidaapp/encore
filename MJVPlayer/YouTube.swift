import Foundation
import UIKit
import AVFoundation
import YouTubeKit

// MARK: - Video info

struct VideoOption: Identifiable {
    var id: Int { height }
    let height: Int
    let video: YouTubeKit.Stream
    /// true when the stream has no sound and must be merged with the audio stream
    let needsAudio: Bool
    var isH264 = true
    var label: String { height >= 720 ? "\(height)p HD" : "\(height)p" }
}

struct YTInfo: Identifiable {
    let id: String
    let title: String
    let channel: String
    let description: String
    let thumbnailURL: URL?
    let audio: YouTubeKit.Stream?
    let videoOptions: [VideoOption]
    /// Short summary of what YouTube offered, shown under the buttons (helps when something is missing).
    let formats: String
    var watchURL: String { "https://www.youtube.com/watch?v=\(id)" }
}

enum YTError: LocalizedError {
    case badLink, noStream
    var errorDescription: String? {
        switch self {
        case .badLink: return "This doesn't look like a YouTube link."
        case .noStream: return "No downloadable stream was found for this video."
        }
    }
}

enum YouTubeService {
    /// Accepts watch, youtu.be, shorts, embed, live and music.youtube.com links, or a bare 11-character ID.
    static func videoID(from text: String) -> String? {
        let s = text.trimmed
        func valid(_ id: String) -> String? {
            id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? id : nil
        }
        if let id = valid(s) { return id }
        // The link may be inside shared text ("Check this out https://youtu.be/…")
        let candidate = s.components(separatedBy: .whitespacesAndNewlines).first { $0.contains("youtu") } ?? s
        guard var comps = URLComponents(string: candidate) else { return nil }
        if comps.scheme == nil, let c2 = URLComponents(string: "https://" + candidate) { comps = c2 }
        guard let host = comps.host?.lowercased(), host.contains("youtu") else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be"), let first = parts.first { return valid(first) }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return valid(v) }
        if parts.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(parts[0]) { return valid(parts[1]) }
        return nil
    }

    static func fetchInfo(id: String) async throws -> YTInfo {
        let remoteAllowed = Prefs.bool(Prefs.remoteFallback)
        let yt = YouTube(videoID: id, methods: remoteAllowed ? [.local, .remote] : [.local])
        var streams = try await yt.streams
        var picked = pick(streams)
        var source = "phone"

        // The phone's own extraction sometimes returns only sound. Ask the backup server for the video streams.
        if picked.options.isEmpty, remoteAllowed,
           let remote = try? await YouTube(videoID: id, methods: [.remote]).streams, !remote.isEmpty {
            let second = pick(remote)
            if !second.options.isEmpty {
                streams = remote
                picked = (second.audio ?? picked.audio, second.options)
                source = "backup server"
            }
        }
        guard picked.audio != nil || !picked.options.isEmpty else { throw YTError.noStream }

        let meta = try? await yt.metadata
        let embed = await OnlineServices.oEmbed(videoID: id)
        let title = meta?.title.nonEmpty ?? embed?.title.nonEmpty ?? "YouTube video"
        let formats = "\(streams.count) formats from the \(source): "
            + "\(streams.filterAudioOnly().count) audio, "
            + "\(streams.filterVideoOnly().count) video-only, "
            + "\(streams.filterVideoAndAudio().count) video+audio; "
            + "\(picked.options.count) usable for MP4"
        return YTInfo(id: id, title: title, channel: embed?.author ?? "",
                      description: meta?.description ?? "",
                      thumbnailURL: meta?.thumbnail?.url ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
                      audio: picked.audio, videoOptions: picked.options, formats: formats)
    }

    /// Chooses the best AAC audio and, per height, the best MP4 video the phone can play and merge.
    private static func pick(_ streams: [YouTubeKit.Stream]) -> (audio: YouTubeKit.Stream?, options: [VideoOption]) {
        // Audio: AAC in MP4 (.m4a) plays everywhere on iOS and can be merged into MP4 video.
        let audioOnly = streams.filterAudioOnly()
        let aac = audioOnly.filter { $0.fileExtension == .m4a && $0.isNativelyPlayable }
        let audioPool = aac.isEmpty ? audioOnly.filter { $0.isNativelyPlayable } : aac
        let audio = audioPool.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }

        // Video with sound in one file (usually 360p) needs no merging.
        var byHeight: [Int: VideoOption] = [:]
        for s in streams.filterVideoAndAudio() where s.fileExtension == .mp4 {
            guard let h = s.videoResolution else { continue }
            byHeight[h] = VideoOption(height: h, video: s, needsAudio: false)
        }
        // HD streams have no sound: merged with the audio above. H.264 is preferred because every
        // iPhone plays it; other codecs the phone can decode (HEVC, AV1) are used when no H.264 exists.
        if let audio, audio.fileExtension == .m4a {
            for s in streams.filterVideoOnly() where s.fileExtension == .mp4 {
                guard let h = s.videoResolution else { continue }
                var isH264 = false
                if let codec = s.videoCodec, case .avc1(_) = codec { isH264 = true }
                guard isH264 || s.isNativelyPlayable else { continue }
                let candidate = VideoOption(height: h, video: s, needsAudio: true, isH264: isH264)
                if let existing = byHeight[h] {
                    if !existing.needsAudio { continue }
                    if existing.isH264 && !isH264 { continue }
                    if existing.isH264 == isH264, (existing.video.bitrate ?? 0) >= (s.bitrate ?? 0) { continue }
                }
                byHeight[h] = candidate
            }
        }
        return (audio, byHeight.values.sorted { $0.height > $1.height })
    }

    /// "Artist - Song (Official Video)" → ("Artist", "Song"). Falls back to the channel name as artist.
    static func parseTitle(_ raw: String, channel: String, clean: Bool) -> (artist: String, title: String) {
        var t = raw
        if clean {
            let junk = #"\s*[\(\[【][^\)\]】]*(official|video|audio|lyric|visuali[sz]er|clip|\bhd\b|\bhq\b|4k|\bmv\b|m/v|remaster|klip|sözleri|sozleri)[^\)\]】]*[\)\]】]"#
            t = t.replacingOccurrences(of: junk, with: "", options: [.regularExpression, .caseInsensitive])
            t = t.replacingOccurrences(of: #"\s*\|.*$"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        }
        var ch = channel.replacingOccurrences(of: " - Topic", with: "")
        ch = ch.replacingOccurrences(of: #"VEVO$"#, with: "", options: .regularExpression).trimmed
        if clean {
            for sep in [" - ", " – ", " — "] {
                if let r = t.range(of: sep) {
                    let a = String(t[..<r.lowerBound]).trimmed, b = String(t[r.upperBound...]).trimmed
                    if !a.isEmpty, !b.isEmpty { return (a, b) }
                }
            }
        }
        return (ch, t.isEmpty ? raw : t)
    }

    /// Largest thumbnail available, without the black bars of the 4:3 versions.
    static func thumbnail(id: String, fallback: URL?) async -> UIImage? {
        for name in ["maxresdefault.jpg", "sddefault.jpg", "hqdefault.jpg"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name)") else { continue }
            if let img = await OnlineServices.image(url), img.size.width > 200 {
                return ImageTools.removeLetterbox(img)
            }
        }
        if let fallback, let img = await OnlineServices.image(fallback) { return ImageTools.removeLetterbox(img) }
        return nil
    }

    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
            case .timedOut: return "The connection timed out. Try again."
            default: return u.localizedDescription
            }
        }
        var text = error.localizedDescription
        if !Prefs.bool(Prefs.remoteFallback) {
            text += " If this keeps happening, turn on the backup extraction server in Settings."
        }
        return text
    }
}

// MARK: - Chunked downloader

enum FetchError: LocalizedError {
    case http(Int), empty
    var errorDescription: String? {
        switch self {
        case .http(403): return "YouTube refused the download (403). Try again in a moment."
        case .http(let c): return "Server error \(c)."
        case .empty: return "The server sent an empty response."
        }
    }
}

enum Fetcher {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// googlevideo links carry the file size in the "clen" parameter.
    static func contentLength(_ url: URL) -> Int64? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "clen" }?.value.flatMap { Int64($0) }
    }

    private static func check(_ resp: URLResponse) throws {
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw FetchError.http(h.statusCode) }
    }

    /// Downloads in 8 MB ranges (YouTube throttles single long requests), retrying each range.
    static func download(_ url: URL, to dest: URL, expected: Int64?, progress: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        guard let total = expected, total > 0 else {
            let (tmp, resp) = try await session.download(from: url)
            try check(resp)
            try? handle.close()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            progress(1)
            return
        }

        let chunk: Int64 = 8 * 1024 * 1024
        var offset: Int64 = 0
        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + chunk, total) - 1
            var attempt = 0
            while true {
                do {
                    var req = URLRequest(url: url)
                    req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                    let (data, resp) = try await session.data(for: req)
                    try check(resp)
                    if data.isEmpty { throw FetchError.empty }
                    try handle.write(contentsOf: data)
                    offset += Int64(data.count)
                    progress(offset)
                    break
                } catch {
                    try Task.checkCancellation()
                    attempt += 1
                    if attempt >= 4 { throw error }
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
    }
}

// MARK: - Download manager

struct DownloadJob: Identifiable {
    enum State: Equatable {
        case waiting, downloading, processing, done, failed(String)
    }
    let id = UUID()
    let videoID: String
    let title: String
    let channel: String
    let thumbnailURL: URL?
    let audioOnly: Bool
    let height: Int?
    var state: State = .waiting
    var progress: Double = 0
    var trackID: UUID?

    var isActive: Bool {
        switch state {
        case .waiting, .downloading, .processing: return true
        default: return false
        }
    }
}

@MainActor
final class BackgroundTaskBox {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var jobs: [DownloadJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(_ info: YTInfo, audioOnly: Bool, option: VideoOption?) {
        let job = DownloadJob(videoID: info.id, title: info.title, channel: info.channel,
                              thumbnailURL: info.thumbnailURL, audioOnly: audioOnly, height: option?.height)
        jobs.insert(job, at: 0)
        let jid = job.id
        tasks[jid] = Task { [weak self] in
            await self?.run(jid, info: info, audioOnly: audioOnly, option: option)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { $0.state = .failed("Cancelled") }
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    func retry(_ job: DownloadJob) {
        remove(job.id)
        Task {
            do {
                let info = try await YouTubeService.fetchInfo(id: job.videoID)
                let option = job.height.flatMap { h in info.videoOptions.first { $0.height == h } } ?? info.videoOptions.first
                start(info, audioOnly: job.audioOnly, option: option)
            } catch {
                AppState.shared.showToast(YouTubeService.describe(error))
            }
        }
    }

    private func update(_ id: UUID, _ body: (inout DownloadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[i])
    }

    fileprivate func setProgress(_ id: UUID, _ p: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if p >= 1 || p - jobs[i].progress >= 0.01 { jobs[i].progress = min(p, 1) }
    }

    private func run(_ jid: UUID, info: YTInfo, audioOnly: Bool, option: VideoOption?) async {
        let bg = BackgroundTaskBox()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "youtube-download") {
            bg.end()
        }
        defer {
            bg.end()
            tasks[jid] = nil
        }

        let work = Paths.temp.appendingPathComponent(jid.uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            update(jid) { $0.state = .downloading }
            let names = YouTubeService.parseTitle(info.title, channel: info.channel, clean: Prefs.bool(Prefs.cleanTitles))
            async let thumbTask = YouTubeService.thumbnail(id: info.id, fallback: info.thumbnailURL)

            var parts: [(stream: YouTubeKit.Stream, file: URL)] = []
            if audioOnly {
                guard let a = info.audio else { throw YTError.noStream }
                parts.append((a, work.appendingPathComponent("audio.m4a")))
            } else {
                guard let o = option else { throw YTError.noStream }
                parts.append((o.video, work.appendingPathComponent("video.mp4")))
                if o.needsAudio {
                    guard let a = info.audio else { throw YTError.noStream }
                    parts.append((a, work.appendingPathComponent("audio.m4a")))
                }
            }

            let sizes = parts.map { Fetcher.contentLength($0.stream.url) ?? 0 }
            let total = max(sizes.reduce(0, +), 1)
            var done: Int64 = 0
            let partCount = parts.count
            for (i, part) in parts.enumerated() {
                try await part.stream.waitUntilAvailable()
                let base = done
                let size = sizes[i]
                let manager = self
                try await Fetcher.download(part.stream.url, to: part.file, expected: size > 0 ? size : nil) { bytes in
                    let p = size > 0 ? Double(base + bytes) / Double(total) : Double(i + 1) / Double(partCount)
                    Task { @MainActor in manager.setProgress(jid, p) }
                }
                done += sizes[i]
            }

            update(jid) { $0.state = .processing; $0.progress = 1 }
            let thumb = await thumbTask
            let cover = thumb.map { ImageTools.prepared($0, square: audioOnly) }
            let tags = MediaExporter.metadata(title: names.title, artist: names.artist, album: "",
                                              comment: info.description, artwork: cover?.jpegData(compressionQuality: 0.86))

            let baseName = MediaImporter.safeFileName(names.artist.isEmpty ? names.title : "\(names.artist) - \(names.title)")
            let dest = MediaImporter.uniqueURL(in: Paths.media, name: baseName + (audioOnly ? ".m4a" : ".mp4"))
            if audioOnly {
                try await MediaExporter.finalize(parts[0].file, to: dest, type: .m4a, metadata: tags)
            } else if parts.count == 2 {
                try await MediaExporter.mux(video: parts[0].file, audio: parts[1].file, to: dest, metadata: tags)
            } else {
                try await MediaExporter.finalize(parts[0].file, to: dest, type: .mp4, metadata: tags)
            }

            var t = Track()
            t.kind = audioOnly ? .audio : .video
            t.fileName = dest.lastPathComponent
            t.title = names.title
            t.artist = names.artist
            t.channel = info.channel.nonEmpty
            t.notes = info.description.nonEmpty
            t.source = "youtube"
            t.sourceURL = info.watchURL
            t.duration = await MediaImporter.duration(of: dest)
            if let cover { t.artworkFile = ImageTools.saveArtwork(cover, square: audioOnly) }
            LibraryStore.shared.add([t])
            update(jid) { $0.state = .done; $0.trackID = t.id }
            AppState.shared.showToast("Downloaded: \(names.title)")
        } catch {
            if Task.isCancelled || error is CancellationError {
                update(jid) { $0.state = .failed("Cancelled") }
            } else {
                update(jid) { $0.state = .failed(YouTubeService.describe(error)) }
            }
        }
    }
}
