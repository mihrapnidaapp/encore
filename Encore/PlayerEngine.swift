import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: Int { case off, all, one }

/// Time updates live in their own object so that lists don't redraw several times a second.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine(library: .shared)

    /// The player that is currently audible. Two players take turns so songs can crossfade.
    @Published private(set) var player = AVPlayer()
    private var standby = AVPlayer()
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
    @Published private(set) var loopA: Double?
    @Published private(set) var loopB: Double?

    private var originalQueue: [UUID] = []
    private var currentID: UUID?
    private var countedCurrent = false
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    private var statusObservation: NSKeyValueObservation?
    private var sleepTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var fadingOut: AVPlayer?
    private var lastPersist = Date.distantPast
    private var lastRestart = Date.distantPast
    /// While a seek is running, the position shown is the target, not the old time.
    private var seekTarget: Double?
    private var seekGeneration = 0

    init(library: LibraryStore) {
        self.library = library
        for p in [player, standby] { configure(p) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        observeStatus()
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
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            // Headphones unplugged: pause like every other player does.
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        })
        setupRemoteCommands()
        restoreState()
    }

    private func configure(_ p: AVPlayer) {
        p.automaticallyWaitsToMinimizeStalling = false
        p.actionAtItemEnd = .pause
    }

    private func observeStatus() {
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlaying() }
        }
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

    /// Position read straight from the player (or the pending seek target).
    var position: Double {
        if let seekTarget { return seekTarget }
        let s = player.currentTime().seconds
        return s.isFinite ? max(s, 0) : 0
    }

    var duration: Double {
        if let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0 { return d.seconds }
        return currentTrack?.duration ?? 0
    }

    private func tick() {
        let t = position
        clock.time = t
        let d = duration
        if abs(clock.duration - d) > 0.25 { clock.duration = d }

        if let a = loopA, let b = loopB, b > a, t >= b, seekTarget == nil {
            seek(to: a)
            return
        }
        checkCrossfade(time: t, duration: d)
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

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        Equalizer.attach(to: item, asset: asset)
        return item
    }

    private func load(index i: Int, autoplay: Bool, startAt: Double? = nil) {
        finishFade()
        saveResumePosition()
        clearLoop()
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
        player.replaceCurrentItem(with: makeItem(url))
        player.volume = 1
        currentID = t.id
        countedCurrent = false
        seekTarget = nil
        clock.time = 0
        clock.duration = t.duration

        var start = startAt
        if start == nil, Prefs.bool(Prefs.resumeLong), let r = t.resumePosition,
           (t.kind == .video || t.duration > 600), r > 5, r < t.duration - 10 {
            start = r
        }
        if let s = start, s > 0 { seek(to: s) }
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
        let d = duration
        if d > 0, position >= d - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        if let id = currentID, !countedCurrent {
            countedCurrent = true
            library.markPlayed(id)
        }
    }

    func pause() {
        finishFade()
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

    /// First press goes back to the start of the song. Pressing again right away
    /// (or within the first seconds of the song) goes to the previous song.
    func previous() {
        guard !queue.isEmpty else { return }
        finishFade()
        let now = Date()
        let pressedAgain = now.timeIntervalSince(lastRestart) < 4
        if position > 2, !pressedAgain {
            seek(to: 0)
            lastRestart = now
            return
        }
        lastRestart = .distantPast
        if index > 0 {
            load(index: index - 1, autoplay: true)
        } else if repeatMode == .all {
            load(index: queue.count - 1, autoplay: true)
        } else {
            seek(to: 0)
            lastRestart = now
        }
    }

    func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        let d = duration
        let s = d > 0 ? min(max(0, seconds), max(d - 0.25, 0)) : max(0, seconds)
        seekGeneration += 1
        let generation = seekGeneration
        seekTarget = s
        clock.time = s
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seekFinished(generation) }
        }
        updateNowPlaying()
    }

    private func seekFinished(_ generation: Int) {
        guard generation == seekGeneration else { return }
        seekTarget = nil
        clock.time = position
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        standby.defaultRate = r
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
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        persistState()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: setRepeat(.all)
        case .all: setRepeat(.one)
        case .one: setRepeat(.off)
        }
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        let c = MPRemoteCommandCenter.shared()
        switch mode {
        case .off: c.changeRepeatModeCommand.currentRepeatType = .off
        case .all: c.changeRepeatModeCommand.currentRepeatType = .all
        case .one: c.changeRepeatModeCommand.currentRepeatType = .one
        }
        persistState()
    }

    func setShuffle(_ on: Bool) {
        if on != shuffle { toggleShuffle() }
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
        finishFade()
        saveResumePosition()
        player.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        index = 0
        currentID = nil
        clearLoop()
        clock.time = 0
        clock.duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistState()
    }

    // MARK: A-B loop

    /// First call marks A, second marks B (the section then repeats), third clears it.
    func cycleLoop() {
        if loopA == nil {
            loopA = position
            AppState.shared.showToast("Loop start (A) set at \(formatTime(position))")
        } else if loopB == nil {
            let b = position
            guard let a = loopA, b > a + 0.5 else {
                AppState.shared.showToast("B must be after A")
                return
            }
            loopB = b
            AppState.shared.showToast("Looping \(formatTime(a)) – \(formatTime(b))")
            seek(to: a)
        } else {
            clearLoop()
            AppState.shared.showToast("Loop off")
        }
    }

    func clearLoop() {
        loopA = nil
        loopB = nil
    }

    // MARK: Crossfade

    private var crossfadeSeconds: Double { UserDefaults.standard.double(forKey: Prefs.crossfade) }

    private func checkCrossfade(time: Double, duration d: Double) {
        let fade = crossfadeSeconds
        guard fade > 0, isPlaying, fadeTask == nil, seekTarget == nil, loopB == nil,
              repeatMode != .one, !sleepAfterTrack, d > fade * 2 + 4,
              let cur = currentTrack, cur.kind == .audio else { return }
        let remaining = (d - time) / Double(max(rate, 0.1))
        guard remaining <= fade, remaining > 0.3 else { return }
        let nextIndex: Int
        if index + 1 < queue.count { nextIndex = index + 1 }
        else if repeatMode == .all { nextIndex = 0 }
        else { return }
        guard let nt = library.track(queue[nextIndex]), nt.kind == .audio else { return }
        let url = library.fileURL(nt)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        startCrossfade(to: nextIndex, track: nt, url: url, over: remaining)
    }

    private func startCrossfade(to nextIndex: Int, track nt: Track, url: URL, over seconds: Double) {
        if let id = currentID { library.setResume(id, nil) }
        let outgoing = player
        let incoming = standby
        incoming.replaceCurrentItem(with: makeItem(url))
        incoming.volume = 0
        incoming.defaultRate = rate
        incoming.playImmediately(atRate: rate)

        standby = outgoing
        player = incoming
        fadingOut = outgoing
        observeStatus()

        index = nextIndex
        currentID = nt.id
        countedCurrent = true
        library.markPlayed(nt.id)
        clock.time = 0
        clock.duration = nt.duration
        updateNowPlaying(full: true)
        persistState()

        let steps = max(Int(seconds * 20), 1)
        fadeTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                let p = Float(step) / Float(steps)
                // Equal-power curve keeps the loudness steady through the fade.
                incoming.volume = sin(p * .pi / 2)
                outgoing.volume = cos(p * .pi / 2)
            }
            self?.finishFade()
        }
    }

    /// Ends a running crossfade at once: the new song at full volume, the old one stopped.
    private func finishFade() {
        fadeTask?.cancel()
        fadeTask = nil
        if let old = fadingOut {
            old.pause()
            old.replaceCurrentItem(with: nil)
            old.volume = 1
            fadingOut = nil
            player.volume = 1
        }
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
        finishFade()
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
        let pos = position
        library.setResume(id, (pos > 5 && pos < t.duration - 10) ? pos : nil)
    }

    func persistState() {
        lastPersist = Date()
        let d = UserDefaults.standard
        d.set(queue.map(\.uuidString), forKey: "pe.queue")
        d.set(index, forKey: "pe.index")
        d.set(position, forKey: "pe.time")
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
        standby.defaultRate = rate
        shuffle = d.bool(forKey: "pe.shuffle")
        contextTitle = d.string(forKey: "pe.context") ?? ""
        let ids = (d.stringArray(forKey: "pe.queue") ?? []).compactMap { UUID(uuidString: $0) }.filter { library.track($0) != nil }
        guard !ids.isEmpty else { return }
        queue = ids
        originalQueue = ids
        let i = min(max(d.integer(forKey: "pe.index"), 0), ids.count - 1)
        load(index: i, autoplay: false, startAt: d.double(forKey: "pe.time"))
    }

    // MARK: Lock screen / Control Center / CarPlay Now Playing

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
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch e.repeatType {
            case .one: mode = .one
            case .all: mode = .all
            default: mode = .off
            }
            Task { @MainActor in self?.setRepeat(mode) }
            return .success
        }
        c.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = e.shuffleType != .off
            Task { @MainActor in self?.setShuffle(on) }
            return .success
        }
        c.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let id = self.currentID else { return }
                self.library.toggleFavorite(id)
                self.updateNowPlaying(full: true)
            }
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
            // Long videos and podcasts get ±15 s buttons on the lock screen; songs keep previous/next.
            let long = t.kind == .video || t.duration > 1200
            let c = MPRemoteCommandCenter.shared()
            c.skipForwardCommand.isEnabled = long
            c.skipBackwardCommand.isEnabled = long
            c.likeCommand.isActive = t.favorite
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
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
