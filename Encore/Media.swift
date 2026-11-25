import AVFoundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Images

enum ImageTools {
    /// Center-crops to a square (optional) and limits the longest side.
    static func prepared(_ image: UIImage, square: Bool, maxSide: CGFloat = 900) -> UIImage {
        guard let cg = image.cgImage ?? render(image).cgImage else { return image }
        var rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        if square {
            let side = min(rect.width, rect.height)
            rect = CGRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side)
        }
        guard let cropped = cg.cropping(to: rect.integral) else { return image }
        let w = CGFloat(cropped.width), h = CGFloat(cropped.height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// YouTube's hq/sd thumbnails are 4:3 with black bars around a 16:9 picture; cut the bars off.
    static func removeLetterbox(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard abs(w / h - 4.0 / 3.0) < 0.05 else { return image }
        let newH = w * 9 / 16
        guard let c = cg.cropping(to: CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH).integral) else { return image }
        return UIImage(cgImage: c)
    }

    private static func render(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    /// Saves artwork as JPEG in the artwork folder and returns its file name.
    static func saveArtwork(_ image: UIImage, square: Bool) -> String? {
        let img = prepared(image, square: square)
        guard let data = img.jpegData(compressionQuality: 0.86) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: Paths.artwork.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }
}

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    func cached(_ name: String) -> UIImage? { cache.object(forKey: name as NSString) }

    func image(_ name: String) async -> UIImage? {
        if let c = cached(name) { return c }
        let url = Paths.artwork.appendingPathComponent(name)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        if let img { cache.setObject(img, forKey: name as NSString) }
        return img
    }
}

// MARK: - Import

struct FileMeta {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var trackNumber: Int?
    var duration: Double = 0
    var artwork: Data?
}

enum ImportError: Error { case unsupported }

enum MediaImporter {
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "m4b", "alac", "mp2"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if audioExts.contains(ext) { return .audio }
        if videoExts.contains(ext) { return .video }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return nil
    }

    static func importBatch(_ urls: [URL], move: Bool) async -> (tracks: [Track], failed: Int) {
        var scoped: [URL] = []
        for u in urls where u.startAccessingSecurityScopedResource() { scoped.append(u) }
        defer { for u in scoped { u.stopAccessingSecurityScopedResource() } }

        let files = expand(urls)
        let images = files.filter { imageExts.contains($0.pathExtension.lowercased()) }
        let media = files.filter { kind(for: $0) != nil }

        var out: [Track] = []
        var failed = 0
        for src in media {
            do { out.append(try await importOne(src, images: images, move: move)) } catch { failed += 1 }
        }
        return (out, failed)
    }

    /// Lists the files inside any folders (synchronous: FileManager's enumerator can't be iterated in async code).
    private static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    while let f = e.nextObject() as? URL { files.append(f) }
                }
            } else {
                files.append(u)
            }
        }
        return files
    }

    static func importOne(_ src: URL, images: [URL], move: Bool) async throws -> Track {
        guard let kind = kind(for: src) else { throw ImportError.unsupported }
        let dest = uniqueURL(in: Paths.media, name: src.lastPathComponent)
        if move { try FileManager.default.moveItem(at: src, to: dest) } else { try FileManager.default.copyItem(at: src, to: dest) }

        let meta = await readMetadata(dest)
        let parsed = parseFileName(src.lastPathComponent)
        var t = Track()
        t.kind = kind
        t.fileName = dest.lastPathComponent
        t.title = meta.title?.nonEmpty ?? parsed.title
        t.artist = meta.artist?.nonEmpty ?? parsed.artist
        t.album = meta.album ?? ""
        t.genre = meta.genre ?? ""
        t.year = meta.year ?? ""
        t.trackNumber = meta.trackNumber
        t.duration = meta.duration

        var cover = meta.artwork.flatMap { UIImage(data: $0) }
        if cover == nil, let side = sidecarImage(for: src, in: images) { cover = UIImage(contentsOfFile: side.path) }
        if cover == nil, kind == .video { cover = await videoFrame(dest, duration: meta.duration) }
        if let cover { t.artworkFile = ImageTools.saveArtwork(cover, square: kind == .audio) }
        return t
    }

    /// "03 - Artist - Title.mp3" → (artist, title)
    static func parseFileName(_ name: String) -> (artist: String, title: String) {
        var s = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._)]\s*"#, with: "", options: .regularExpression).trimmed
        for sep in [" - ", " – ", " — "] {
            if let r = s.range(of: sep) {
                return (String(s[..<r.lowerBound]).trimmed, String(s[r.upperBound...]).trimmed)
            }
        }
        return ("", s)
    }

    static func sidecarImage(for media: URL, in images: [URL]) -> URL? {
        let base = media.deletingPathExtension().lastPathComponent.lowercased()
        let dir = media.deletingLastPathComponent().path
        if let same = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == base }) { return same }
        let names = ["cover", "folder", "front", "album", "albumart"]
        return images.first {
            $0.deletingLastPathComponent().path == dir && names.contains($0.deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        let short = String(cleaned.prefix(120))
        return short.isEmpty ? "Untitled" : short
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    static func duration(of url: URL) async -> Double {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return 0 }
        return d.seconds
    }

    static func readMetadata(_ url: URL) async -> FileMeta {
        var m = FileMeta()
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.isNumeric { m.duration = d.seconds }
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            let ident = item.identifier
            switch item.commonKey {
            case .some(.commonKeyTitle):
                if m.title == nil { m.title = try? await item.load(.stringValue) }
                continue
            case .some(.commonKeyArtist):
                if m.artist == nil { m.artist = try? await item.load(.stringValue) }
                continue
            case .some(.commonKeyAlbumName):
                if m.album == nil { m.album = try? await item.load(.stringValue) }
                continue
            case .some(.commonKeyArtwork):
                if m.artwork == nil { m.artwork = try? await item.load(.dataValue) }
                continue
            case .some(.commonKeyCreationDate):
                if m.year == nil, let s = try? await item.load(.stringValue) { m.year = firstYear(s) }
                continue
            default: break
            }
            if ident == .id3MetadataTrackNumber, m.trackNumber == nil, let s = try? await item.load(.stringValue) {
                m.trackNumber = Int(s.split(separator: "/").first.map(String.init)?.trimmed ?? "")
            } else if ident == .iTunesMetadataTrackNumber, m.trackNumber == nil, let d = try? await item.load(.dataValue), d.count >= 4 {
                let n = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                if n > 0 { m.trackNumber = n }
            } else if ident == .id3MetadataContentType || ident == .iTunesMetadataUserGenre || ident == .quickTimeMetadataGenre,
                      m.genre == nil, let s = try? await item.load(.stringValue) {
                let g = s.replacingOccurrences(of: #"^\(\d+\)"#, with: "", options: .regularExpression).trimmed
                if !g.isEmpty { m.genre = g }
            } else if ident == .id3MetadataYear || ident == .id3MetadataRecordingTime || ident == .iTunesMetadataReleaseDate,
                      m.year == nil, let s = try? await item.load(.stringValue) {
                m.year = firstYear(s)
            }
        }
        return m
    }

    private static func firstYear(_ s: String) -> String? {
        guard let r = s.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    static func videoFrame(_ url: URL, duration: Double, at time: Double? = nil) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1000, height: 1000)
        let seconds = time ?? min(max(duration * 0.1, 1), 30)
        guard let result = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

// MARK: - Export (writing tags, merging YouTube video + audio)

enum ExportError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let m): return m }
    }
}

enum MediaExporter {
    static func metadata(title: String, artist: String, album: String, comment: String, artwork: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            item.extendedLanguageTag = "und"
            if let dataType { item.dataType = dataType }
            items.append(item)
        }
        if !title.isEmpty { add(.commonIdentifierTitle, title as NSString) }
        if !artist.isEmpty { add(.commonIdentifierArtist, artist as NSString) }
        if !album.isEmpty { add(.commonIdentifierAlbumName, album as NSString) }
        if !comment.isEmpty { add(.commonIdentifierDescription, String(comment.prefix(2000)) as NSString) }
        if let artwork { add(.commonIdentifierArtwork, artwork as NSData, dataType: kCMMetadataBaseDataType_JPEG as String) }
        return items
    }

    /// Rewrites the downloaded audio into a proper .m4a with tags; falls back to a plain copy.
    static func finalize(_ src: URL, to dest: URL, type: AVFileType, metadata: [AVMetadataItem]) async throws {
        do {
            try await export(AVURLAsset(url: src), to: dest, type: type, metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
        }
    }

    /// Merges a video-only and an audio-only stream into one .mp4 without re-encoding.
    static func mux(video: URL, audio: URL, to dest: URL, metadata: [AVMetadataItem]) async throws {
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
              let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first
        else { throw ExportError.failed("The downloaded streams could not be read.") }
        let vDur = try await vAsset.load(.duration)
        let aDur = try await aAsset.load(.duration)
        let duration = CMTimeMinimum(vDur, aDur)

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.failed("Could not prepare the video.") }
        let range = CMTimeRange(start: .zero, duration: duration)
        try cv.insertTimeRange(range, of: vTrack, at: .zero)
        try ca.insertTimeRange(range, of: aTrack, at: .zero)
        cv.preferredTransform = try await vTrack.load(.preferredTransform)
        try await export(comp, to: dest, type: .mp4, metadata: metadata)
    }

    private static func export(_ asset: AVAsset, to dest: URL, type: AVFileType, metadata: [AVMetadataItem]) async throws {
        try? FileManager.default.removeItem(at: dest)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.failed("Could not start export.")
        }
        session.outputURL = dest
        session.outputFileType = type
        session.metadata = metadata
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status != .completed {
            throw session.error ?? ExportError.failed("Export failed.")
        }
    }
}

// MARK: - Lyrics (LRC)

struct LyricLine: Identifiable {
    let id: Int
    let time: Double?
    let text: String
}

enum LRC {
    private static let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let meta = try! NSRegularExpression(pattern: #"^\[[a-zA-Z]+:.*\]\s*$"#)

    static func parse(_ text: String) -> [LyricLine] {
        var timed: [(Double, String)] = []
        var plain: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = tag.matches(in: raw, range: full)
            if matches.isEmpty {
                if meta.firstMatch(in: raw, range: full) == nil { plain.append(raw.trimmed) }
                continue
            }
            let lyric = ns.substring(from: matches[matches.count - 1].range.upperBound).trimmed
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append((min * 60 + sec, lyric))
            }
        }
        if !timed.isEmpty {
            return timed.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        }
        while plain.first == "" { plain.removeFirst() }
        while plain.last == "" { plain.removeLast() }
        return plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }

    static func currentIndex(_ lines: [LyricLine], time: Double) -> Int? {
        var idx: Int?
        for l in lines {
            guard let t = l.time else { return nil }
            if t <= time + 0.3 { idx = l.id } else { break }
        }
        return idx
    }
}
