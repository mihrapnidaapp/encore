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
    case stalled(Error, received: Int64)
    var errorDescription: String? {
        switch self {
        case .stalled(let error, let received):
            let reason = (error as? URLError)?.code == .timedOut ? "YouTube's video server did not answer"
                : error.localizedDescription
            return received > 0 ? "\(reason) after \(DownloadManager.megabytes(received))." : "\(reason) (no data received)."
        case .http(403): return "YouTube refused the download (403). Try again in a moment."
        case .http(let c): return "Server error \(c)."
        case .empty: return "The server sent an empty response."
        }
    }
}

enum Fetcher {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
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

    /// Downloads in 8 MB ranges (YouTube throttles single long requests). Bytes are written and reported
    /// as they arrive, so progress moves even on a slow connection. A failed or stalled range is resumed
    /// from the last byte received, up to 4 times in a row.
    static func download(_ url: URL, to dest: URL, expected: Int64?, progress: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        let chunk: Int64 = 8 * 1024 * 1024
        let flushSize = 256 * 1024
        var total = expected ?? 0
        var offset: Int64 = 0
        var attempt = 0
        enum Style { case header, query, whole }
        var style = Style.header
        while total <= 0 || offset < total {
            try Task.checkCancellation()
            // If nothing at all arrives, switch how the range is asked for: Range header, then the
            // "range=" URL parameter the YouTube web player uses, then one plain request for the whole file.
            if offset == 0, attempt >= 2, style == .header { style = .query; attempt = 0 }
            else if offset == 0, attempt >= 2, style == .query { style = .whole; attempt = 0; total = 0 }
            var req = URLRequest(url: url)
            if total > 0, style != .whole {
                let end = min(offset + chunk, total) - 1
                if style == .query, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "range" }
                        + [URLQueryItem(name: "range", value: "\(offset)-\(end)")]
                    req.url = comps.url ?? url
                } else {
                    req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                }
            } else if offset > 0 {
                req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
            let before = offset
            do {
                let (bytes, resp) = try await session.bytes(for: req)
                try check(resp)
                if total == 0 {
                    // Size unknown: one open-ended request; the response says how big the file is.
                    let length = resp.expectedContentLength
                    total = length > 0 ? offset + length : -1
                }
                var buffer = Data()
                buffer.reserveCapacity(flushSize)
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= flushSize {
                        try handle.write(contentsOf: buffer)
                        offset += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        progress(offset)
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    offset += Int64(buffer.count)
                    progress(offset)
                }
                if offset == before { throw FetchError.empty }
                attempt = 0
                if total < 0 { break }  // unknown size: the single request delivered everything
            } catch {
                try Task.checkCancellation()
                if offset > before { attempt = 0 }  // some data arrived: the range resumes where it stopped
                attempt += 1
                if attempt >= 4 || (style == .whole && offset == 0 && attempt >= 2) {
                    throw FetchError.stalled(error, received: offset)
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }
}

struct PartError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    /// Extra status line: the wait before YouTube serves the file, or bytes and speed while downloading.
    var detail = ""
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
        AppState.shared.showToast(audioOnly ? "Downloading music…" : "Downloading video…")
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

    fileprivate func setProgress(_ id: UUID, _ p: Double, detail: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].progress = min(p, 1)
        jobs[i].detail = detail
    }

    nonisolated static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
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
            let knownTotal = sizes.allSatisfy { $0 > 0 }
            var done: Int64 = 0
            let partCount = parts.count
            for (i, part) in parts.enumerated() {
                // Videos with preroll ads are served only once the ad could have been skipped.
                let wait = Int(part.stream.availableAt.timeIntervalSinceNow.rounded(.up))
                if wait > 0 {
                    update(jid) { $0.detail = "YouTube asks to wait \(wait) s before the download…" }
                }
                try await part.stream.waitUntilAvailable()
                update(jid) { $0.detail = "Connecting…" }
                let base = done
                let size = sizes[i]
                let manager = self
                let started = Date()
                let partName = partCount > 1 ? (i == 0 ? "Video" : "Sound") : (audioOnly ? "Music" : "Video")
                let host = part.stream.url.host ?? "?"
                do {
                    try await Fetcher.download(part.stream.url, to: part.file, expected: size > 0 ? size : nil) { bytes in
                        let p = knownTotal ? Double(base + bytes) / Double(total)
                                           : (Double(i) + (size > 0 ? Double(bytes) / Double(size) : 0.5)) / Double(partCount)
                        let elapsed = max(Date().timeIntervalSince(started), 0.1)
                        var text = DownloadManager.megabytes(base + bytes)
                        if knownTotal { text += " of " + DownloadManager.megabytes(total) }
                        text += " · " + DownloadManager.megabytes(Int64(Double(bytes) / elapsed)) + "/s"
                        if partCount > 1 { text += i == 0 ? " · video" : " · sound" }
                        Task { @MainActor in manager.setProgress(jid, p, detail: text) }
                    }
                } catch let error as FetchError {
                    throw PartError(message: "\(partName): \(error.localizedDescription) [\(host)]")
                }
                done += size > 0 ? size : (try? part.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            }

            update(jid) { $0.state = .processing; $0.progress = 1; $0.detail = "" }
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
                let message = YouTubeService.describe(error)
                update(jid) { $0.state = .failed(message) }
                AppState.shared.showToast("Download failed: \(message)")
            }
        }
    }
}
