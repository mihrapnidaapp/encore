import SwiftUI
import AVFoundation
import MediaToolbox

// MARK: - Settings shared with the audio thread

/// The values the audio thread reads. Guarded by a lock; the audio thread only uses `try()`
/// so it never waits on the UI.
final class EQParams {
    static let shared = EQParams()
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    let lock = NSLock()
    private(set) var version = 0
    private(set) var enabled = false
    private(set) var gains = [Float](repeating: 0, count: 10)
    private(set) var preamp: Float = 0

    func set(enabled: Bool, gains: [Float], preamp: Float) {
        lock.lock()
        self.enabled = enabled
        self.gains = gains
        self.preamp = preamp
        version &+= 1
        lock.unlock()
    }
}

// MARK: - Presets

struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        .init(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(name: "Bass Booster", gains: [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        .init(name: "Bass Reducer", gains: [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        .init(name: "Treble Booster", gains: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        .init(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2.5, -4, -5, -6]),
        .init(name: "Vocal Booster", gains: [-2, -2, -1, 1, 3.5, 3.5, 3, 1.5, 0, -1]),
        .init(name: "Loudness", gains: [6, 4, 0, 0, -2, 0, -1, -4, 4, 2]),
        .init(name: "Rock", gains: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        .init(name: "Pop", gains: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        .init(name: "Hip-Hop", gains: [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        .init(name: "Electronic", gains: [4.5, 4, 1.5, 0, -2, 2, 1, 1.5, 4, 5]),
        .init(name: "Dance", gains: [4, 6.5, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0]),
        .init(name: "Jazz", gains: [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]),
        .init(name: "Classical", gains: [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]),
        .init(name: "Acoustic", gains: [4.5, 4.5, 3.5, 1, 2, 1.5, 3, 3.5, 3, 2]),
        .init(name: "Piano", gains: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        .init(name: "R&B", gains: [2.5, 7, 5.5, 1.5, -2.5, -1.5, 2.5, 3, 3, 3.5]),
        .init(name: "Latin", gains: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        .init(name: "Deep", gains: [5, 3.5, 1.5, 1, 3, 2.5, 1.5, -2, -3.5, -4.5]),
        .init(name: "Late Night", gains: [3, 2, 1, 0, 0, 0, 0, -1, -3, -4]),
        .init(name: "Spoken Word", gains: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 4.5, 4, 2, 0]),
        .init(name: "Small Speakers", gains: [5.5, 4, 3.5, 2.5, 1.5, 0, -1.5, -2.5, -3.5, -4]),
        .init(name: "Headphones", gains: [3, 2, 1, 0, 0, 0, 1, 2, 2.5, 2]),
    ]
}

// MARK: - UI model

@MainActor
final class EqualizerStore: ObservableObject {
    static let shared = EqualizerStore()

    @Published var enabled: Bool { didSet { apply() } }
    @Published var gains: [Float] { didSet { apply() } }
    @Published var preamp: Float { didSet { apply() } }
    @Published var presetName: String { didSet { UserDefaults.standard.set(presetName, forKey: "eq.preset") } }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "eq.enabled")
        let saved = (d.array(forKey: "eq.gains") as? [NSNumber])?.map(\.floatValue) ?? []
        gains = saved.count == 10 ? saved : [Float](repeating: 0, count: 10)
        preamp = d.object(forKey: "eq.preamp") == nil ? 0 : d.float(forKey: "eq.preamp")
        presetName = d.string(forKey: "eq.preset") ?? "Flat"
        apply()
    }

    func choose(_ preset: EQPreset) {
        presetName = preset.name
        gains = preset.gains
        // Lower the overall level when bands are boosted so loud songs don't clip.
        preamp = -min(max(preset.gains.max() ?? 0, 0) * 0.5, 6)
        if !enabled { enabled = true }
    }

    func setGain(_ band: Int, _ value: Float) {
        var g = gains
        g[band] = (value * 2).rounded() / 2
        gains = g
        presetName = "Custom"
    }

    private func apply() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "eq.enabled")
        d.set(gains, forKey: "eq.gains")
        d.set(preamp, forKey: "eq.preamp")
        EQParams.shared.set(enabled: enabled, gains: gains, preamp: preamp)
    }
}

// MARK: - Audio tap

enum Equalizer {
    /// Adds the equalizer to an item. The audio track is loaded asynchronously; the mix is
    /// attached as soon as it is ready (a few milliseconds for local files).
    @MainActor
    static func attach(to item: AVPlayerItem, asset: AVAsset) {
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let mix = makeMix(track) else { return }
            item.audioMix = mix
        }
    }

    private static func makeMix(_ track: AVAssetTrack) -> AVAudioMix? {
        let context = EQTapContext()
        let info = Unmanaged.passRetained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: info,
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: nil,
            process: eqTapProcess
        )
        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tapRef)
        guard status == noErr, let tap = tapRef?.takeRetainedValue() else {
            Unmanaged<EQTapContext>.fromOpaque(info).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

private let eqTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let eqTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let eqTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let asbd = format.pointee
    ctx.prepare(sampleRate: asbd.mSampleRate,
                isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32)
}

private let eqTapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.process(bufferList, frames: Int(framesOut.pointee))
}

/// Per-item filter state: ten peaking biquad filters (RBJ cookbook) per channel.
final class EQTapContext {
    private static let bands = 10
    private static let maxChannels = 8

    private var sampleRate: Double = 44_100
    private var isFloat = true
    private var version = -1
    private var active = false
    private var preamp: Float = 1
    private var bandCount = 0
    private let bandIndex = UnsafeMutablePointer<Int>.allocate(capacity: EQTapContext.bands)
    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: EQTapContext.bands * 5)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: EQTapContext.bands * EQTapContext.maxChannels * 4)

    init() {
        bandIndex.initialize(repeating: 0, count: Self.bands)
        coeffs.initialize(repeating: 0, count: Self.bands * 5)
        state.initialize(repeating: 0, count: Self.bands * Self.maxChannels * 4)
    }

    deinit {
        bandIndex.deallocate()
        coeffs.deallocate()
        state.deallocate()
    }

    func prepare(sampleRate: Double, isFloat: Bool) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100
        self.isFloat = isFloat
        version = -1
        state.update(repeating: 0, count: Self.bands * Self.maxChannels * 4)
    }

    private func refresh() {
        let p = EQParams.shared
        guard p.lock.try() else { return }
        defer { p.lock.unlock() }
        guard p.version != version else { return }
        version = p.version
        active = p.enabled
        preamp = powf(10, p.preamp / 20)
        bandCount = 0
        for b in 0..<Self.bands {
            let gain = Double(p.gains[b])
            let f = EQParams.frequencies[b]
            guard abs(gain) >= 0.05, f < sampleRate * 0.45 else { continue }
            let a = pow(10, gain / 40)
            let w0 = 2 * Double.pi * f / sampleRate
            let alpha = sin(w0) / (2 * 1.41)
            let cosw = cos(w0)
            let a0 = 1 + alpha / a
            let c = coeffs + b * 5
            c[0] = (1 + alpha * a) / a0
            c[1] = (-2 * cosw) / a0
            c[2] = (1 - alpha * a) / a0
            c[3] = (-2 * cosw) / a0
            c[4] = (1 - alpha / a) / a0
            bandIndex[bandCount] = b
            bandCount += 1
        }
        if bandCount == 0 && abs(p.preamp) < 0.05 { active = false }
    }

    func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        refresh()
        guard active, isFloat, frames > 0 else { return }
        let list = UnsafeMutableAudioBufferListPointer(abl)
        var channelBase = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let nch = max(Int(buffer.mNumberChannels), 1)
            for c in 0..<nch {
                let ch = min(channelBase + c, Self.maxChannels - 1)
                var i = c
                for _ in 0..<frames {
                    var x = Double(data[i] * preamp)
                    for k in 0..<bandCount {
                        let b = bandIndex[k]
                        let co = coeffs + b * 5
                        let s = state + (b * Self.maxChannels + ch) * 4
                        let y = co[0] * x + co[1] * s[0] + co[2] * s[1] - co[3] * s[2] - co[4] * s[3]
                        s[1] = s[0]; s[0] = x
                        s[3] = s[2]; s[2] = y
                        x = y
                    }
                    data[i] = Float(min(max(x, -1), 1))
                    i += nch
                }
            }
            channelBase += nch
        }
    }
}

// MARK: - Screen

struct EqualizerView: View {
    @ObservedObject var eq = EqualizerStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.crossfade) private var crossfade = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Toggle("Equalizer", isOn: $eq.enabled).font(.headline)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EQPreset.all) { p in
                                Button(p.name) { eq.choose(p) }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(eq.presetName == p.name ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<10, id: \.self) { b in
                            VStack(spacing: 6) {
                                Text(String(format: "%+.0f", eq.gains[b])).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                VerticalSlider(value: Binding(get: { eq.gains[b] }, set: { eq.setGain(b, $0) }), range: -12...12)
                                    .frame(height: 200)
                                Text(label(EQParams.frequencies[b])).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .opacity(eq.enabled ? 1 : 0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Preamp")
                            Spacer()
                            Text(String(format: "%+.1f dB", eq.preamp)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $eq.preamp, in: -12...12, step: 0.5)
                    }
                    .opacity(eq.enabled ? 1 : 0.4)

                    Button("Reset to Flat") { eq.choose(EQPreset.all[0]) }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Crossfade")
                            Spacer()
                            Text(crossfade == 0 ? "Off" : "\(Int(crossfade)) s").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $crossfade, in: 0...12, step: 1)
                        Text("Songs blend into each other at the end. Videos always play without crossfade.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func label(_ f: Double) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }
}

/// A vertical slider driven by a drag gesture (rotated system sliders are hard to hit).
struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((value - range.lowerBound) / span)
            let mid = h / 2
            let y = h * (1 - frac)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.15)).frame(width: 4)
                Rectangle().fill(Color.accentColor)
                    .frame(width: 4, height: abs(mid - y))
                    .offset(y: min(mid, y))
                Rectangle().fill(Color.white.opacity(0.3)).frame(width: 12, height: 1).offset(y: mid)
                Circle().fill(Color.white)
                    .frame(width: 22, height: 22)
                    .shadow(radius: 2)
                    .offset(y: y - 11)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = Float(1 - min(max(g.location.y / h, 0), 1))
                value = range.lowerBound + f * span
            })
        }
    }
}
