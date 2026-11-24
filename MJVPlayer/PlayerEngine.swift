import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: Int { case off, all, one }

/// Time updates live in their own object so that lists don't redraw twice a second.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine(library: .shared)

    let player = AVPlayer()
    let clock = PlaybackClock()
    let library: LibraryStore

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var rate: Float = 1
    @Published private(set) var contextTitle = ""
    @Published private(set) var sleepEnd: Date?
    @Published private(set) var sleepAfterTrack = false

    private var originalQueue: [UUID] = []
    private var currentID: UUID?
    private var countedCurrent = false
    private var observers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var sleepTask: Task<Void, Never>?
    private var lastPersist = Date.distantPast

    init(library: LibraryStore) {
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            let seconds = t.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlaying() }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in self?.itemEnded(item) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            let opts = AVAudioSession.InterruptionOptions(rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            if opts.contains(.shouldResume) { Task { @MainActor in self?.play() } }
        })
        setupRemoteCommands()
        restoreState()
    }

    // MARK: State

    var currentTrack: Track? {
        guard queue.indices.contains(index) else { return nil }
        return library.track(queue[index])
    }

    var upcoming: [Track] {
        guard index + 1 < queue.count else { return [] }
        return queue[(index + 1)...].compactMap { library.track($0) }
    }

    private func tick(_ seconds: Double) {
        if seconds.isFinite { clock.time = seconds }
        if let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0, abs(clock.duration - d.seconds) > 0.5 {
            clock.duration = d.seconds
        }
        if isPlaying, Date().timeIntervalSince(lastPersist) > 5 { persistState() }
    }

    private func syncPlaying() {
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            updateNowPlaying()
        }
    }

    // MARK: Starting playback

    func play(_ tracks: [Track], startAt start: Int = 0, shuffled: Bool = false, context: String = "") {
        guard !tracks.isEmpty else { return }
        let ids = tracks.map(\.id)
        let first = min(max(start, 0), ids.count - 1)
        originalQueue = ids
        contextTitle = context
        if shuffled { shuffle = true }
        if shuffle {
            var rest = ids
            let pick = shuffled ? Int.random(in: 0..<ids.count) : first
            let head = rest.remove(at: pick)
            rest.shuffle()
            queue = [head] + rest
            load(index: 0, autoplay: true)
        } else {
            queue = ids
            load(index: first, autoplay: true)
        }
    }

    func playNext(_ ids: [UUID]) {
        guard !queue.isEmpty else {
            play(ids.compactMap { library.track($0) })
            return
        }
        queue.insert(contentsOf: ids, at: index + 1)
        originalQueue.append(contentsOf: ids)
        persistState()
    }

    func addToQueue(_ ids: [UUID]) {
        guard !queue.isEmpty else {
            play(ids.compactMap { library.track($0) })
            return
        }
        queue.append(contentsOf: ids)
        originalQueue.append(contentsOf: ids)
        persistState()
    }

    private func load(index i: Int, autoplay: Bool, startAt: Double? = nil) {
        saveResumePosition()
        guard queue.indices.contains(i), let t = library.track(queue[i]) else {
            stop()
            return
        }
        index = i
        let url = library.fileURL(t)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppState.shared.showToast("File not found: \(t.displayTitle)")
            player.replaceCurrentItem(with: nil)
            currentID = t.id
            updateNowPlaying(full: true)
            return
        }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        currentID = t.id
        countedCurrent = false
        clock.time = 0
        clock.duration = t.duration

        var start = startAt
        if start == nil, Prefs.bool(Prefs.resumeLong), let r = t.resumePosition,
           (t.kind == .video || t.duration > 600), r > 5, r < t.duration - 10 {
            start = r
        }
        if let s = start, s > 0 {
            player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            clock.time = s
        }
        if autoplay { play() }
        updateNowPlaying(full: true)
        persistState()
    }

    // MARK: Transport

    func play() {
        guard player.currentItem != nil else {
            if !queue.isEmpty { load(index: index, autoplay: true) }
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        if clock.duration > 0, clock.time >= clock.duration - 0.5 { player.seek(to: .zero) }
        player.playImmediately(atRate: rate)
        if let id = currentID, !countedCurrent {
            countedCurrent = true
            library.markPlayed(id)
        }
    }

    func pause() {
        player.pause()
        saveResumePosition()
        persistState()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            load(index: index + 1, autoplay: true)
        } else if repeatMode == .all {
            load(index: 0, autoplay: true)
        } else if auto {
            player.pause()
            seek(to: 0)
            updateNowPlaying()
        } else {
            load(index: 0, autoplay: false)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if clock.time > 3 || (index == 0 && repeatMode != .all) {
            seek(to: 0)
        } else {
            load(index: index > 0 ? index - 1 : queue.count - 1, autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds)
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        clock.time = s
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        let limit = clock.duration > 0 ? clock.duration - 1 : clock.time + seconds
        seek(to: min(max(clock.time + seconds, 0), limit))
    }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if isPlaying { player.rate = r }
        updateNowPlaying()
        persistState()
    }

    func toggleShuffle() {
        guard !queue.isEmpty, queue.indices.contains(index) else {
            shuffle.toggle()
            return
        }
        let current = queue[index]
        if !shuffle {
            originalQueue = queue
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [current] + rest
            index = 0
            shuffle = true
        } else {
            var restored = originalQueue.filter { queue.contains($0) }
            for id in queue where !restored.contains(id) { restored.append(id) }
            queue = restored
            index = restored.firstIndex(of: current) ?? 0
            shuffle = false
        }
        persistState()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        persistState()
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem else { return }
        if let id = currentID { library.setResume(id, nil) }
        if sleepAfterTrack {
            sleepAfterTrack = false
            player.pause()
            seek(to: 0)
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            player.playImmediately(atRate: rate)
        } else {
            next(auto: true)
        }
    }

    func stop() {
        saveResumePosition()
        player.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        index = 0
        currentID = nil
        clock.time = 0
        clock.duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistState()
    }

    // MARK: Queue editing

    func jumpToUpcoming(_ offset: Int) { load(index: index + 1 + offset, autoplay: true) }

    func moveUpcoming(from: IndexSet, to: Int) {
        guard index + 1 <= queue.count else { return }
        var up = Array(queue[(index + 1)...])
        up.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...index]) + up
        persistState()
    }

    func removeUpcoming(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 }.filter { queue.indices.contains($0) })
        queue.remove(atOffsets: absolute)
        persistState()
    }

    func clearUpcoming() {
        guard index + 1 < queue.count else { return }
        queue.removeSubrange((index + 1)...)
        persistState()
    }

    /// Called when tracks are deleted from the library.
    func remove(_ ids: Set<UUID>) {
        guard !queue.isEmpty else { return }
        if let cur = currentID, ids.contains(cur) {
            stop()
            return
        }
        let cur = currentID
        queue.removeAll { ids.contains($0) }
        originalQueue.removeAll { ids.contains($0) }
        index = cur.flatMap { queue.firstIndex(of: $0) } ?? 0
        persistState()
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEnd = nil
        sleepAfterTrack = false
        guard let m = minutes, m > 0 else { return }
        sleepEnd = Date().addingTimeInterval(Double(m * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(m) * 60 * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.fadeOutAndPause()
        }
    }

    func sleepAtEndOfTrack() {
        setSleepTimer(minutes: nil)
        sleepAfterTrack = true
    }

    private func fadeOutAndPause() async {
        for step in stride(from: 10, through: 0, by: -1) {
            player.volume = Float(step) / 10
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        pause()
        player.volume = 1
        sleepEnd = nil
        sleepTask = nil
    }

    // MARK: Resume and persistence

    private func saveResumePosition() {
        guard let id = currentID, let t = library.track(id), t.kind == .video || t.duration > 600 else { return }
        let pos = player.currentTime().seconds
        guard pos.isFinite else { return }
        library.setResume(id, (pos > 5 && pos < t.duration - 10) ? pos : nil)
    }

    func persistState() {
        lastPersist = Date()
        let d = UserDefaults.standard
        let pos = player.currentTime().seconds
        d.set(queue.map(\.uuidString), forKey: "pe.queue")
        d.set(index, forKey: "pe.index")
        d.set(pos.isFinite ? pos : 0, forKey: "pe.time")
        d.set(shuffle, forKey: "pe.shuffle")
        d.set(repeatMode.rawValue, forKey: "pe.repeat")
        d.set(rate, forKey: "pe.rate")
        d.set(contextTitle, forKey: "pe.context")
    }

    private func restoreState() {
        let d = UserDefaults.standard
        repeatMode = RepeatMode(rawValue: d.integer(forKey: "pe.repeat")) ?? .off
        let r = d.float(forKey: "pe.rate")
        rate = r > 0 ? r : 1
        player.defaultRate = rate
        shuffle = d.bool(forKey: "pe.shuffle")
        contextTitle = d.string(forKey: "pe.context") ?? ""
        let ids = (d.stringArray(forKey: "pe.queue") ?? []).compactMap { UUID(uuidString: $0) }.filter { library.track($0) != nil }
        guard !ids.isEmpty else { return }
        queue = ids
        originalQueue = ids
        let i = min(max(d.integer(forKey: "pe.index"), 0), ids.count - 1)
        load(index: i, autoplay: false, startAt: d.double(forKey: "pe.time"))
    }

    // MARK: Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    /// Call after the current track's title or cover changes.
    func refreshNowPlaying(_ id: UUID? = nil) {
        if id == nil || id == currentID { updateNowPlaying(full: true) }
    }

    private func updateNowPlaying(full: Bool = false) {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = full ? [:] : (center.nowPlayingInfo ?? [:])
        if full || info[MPMediaItemPropertyTitle] == nil {
            info[MPMediaItemPropertyTitle] = t.displayTitle
            info[MPMediaItemPropertyArtist] = t.displayArtist
            info[MPMediaItemPropertyAlbumTitle] = t.album
            info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: (t.kind == .video ? MPNowPlayingInfoMediaType.video : .audio).rawValue)
            if let url = library.artworkURL(t), let img = UIImage(contentsOfFile: url.path) {
                info[MPMediaItemPropertyArtwork] = Self.artwork(img)
            }
        }
        let elapsed = player.currentTime().seconds
        info[MPMediaItemPropertyPlaybackDuration] = clock.duration > 0 ? clock.duration : t.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? elapsed : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        center.nowPlayingInfo = info
    }

    /// Built outside the main actor: iOS calls the artwork handler on a background queue.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
