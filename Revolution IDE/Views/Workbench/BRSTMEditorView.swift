import SwiftUI
import AVFoundation
import Accelerate
import Combine
import UniformTypeIdentifiers

/// Editor for a `.brstm` streamed music track: waveform with draggable loop start/end markers,
/// loop-aware preview (including "Play Loop Seam", the only real way to judge a loop point), track
/// volume/pan, replacing the audio from any file macOS can read, and WAV export. Saving re-encodes
/// to DSP-ADPCM (see `BRSTMDocument.serialize`) only when the audio actually changed.
struct BRSTMEditorView: View {
    @ObservedObject var box: BRSTMDocumentBox
    @StateObject private var player = BRSTMPreviewPlayer()
    @State private var previewTrack = 0
    @State private var importError: String?

    private var doc: BRSTMDocument { box.doc }
    private var rate: Double { Double(max(doc.sampleRate, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let source = box.sourceAudioName {
                HStack {
                    Image(systemName: "music.note")
                    Text("Previewing \(source) as it will sound in the game (32 kHz). Set the loop point and end here, then save it as a BRSTM, the original file isn't changed.")
                        .font(.caption)
                    Spacer()
                    Button("Save as .brstm...") { saveAsBRSTM(source) }.buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            header
            waveform
            transport
            Divider()
            HStack(alignment: .top, spacing: 32) {
                loopSettings
                if !doc.tracks.isEmpty { trackSettings }
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { player.stop() }
        .alert("Couldn't import audio", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(codecName), \(doc.channelCount) channel\(doc.channelCount == 1 ? "" : "s"), \(doc.sampleRate) Hz")
                    .font(.headline)
                Text("\(formatTime(doc.durationSeconds, precise: true)) (\(doc.totalSamples) samples)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if box.isEncoding {
                ProgressView().controlSize(.small).padding(.leading, 8)
                Text("Encoding...").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Snapshots are the saved file itself, so one is only taken once encoding has finished.
            AutoHistoryControls(initial: box.doc.serialize(), changes: box.objectWillChange,
                                snapshot: { box.doc.encoded == nil ? nil : box.doc.serialize() },
                                restore: { player.stop(); box.restore($0) })
            Button("Replace Audio...") { replaceAudio() }
                .help("Import any audio file macOS can read (WAV, AIFF, MP3, M4A, FLAC...). It's resampled to 32 kHz like every retail track and loops the whole song until you set a loop point.")
            Button("Export WAV...") { exportWAV() }
        }
    }

    private var codecName: String {
        switch doc.codec {
        case .adpcm: return "DSP-ADPCM"
        case .pcm16: return "PCM16"
        case .pcm8: return "PCM8 (saves as DSP-ADPCM)"
        }
    }

    // MARK: Waveform

    private var waveform: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let length = max(doc.channelSamples.first?.count ?? 0, 1)
            let x = { (sample: Int) -> CGFloat in CGFloat(sample) / CGFloat(length) * width }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
                Canvas { ctx, size in
                    drawWaveform(ctx, size: size)
                    // Past the end marker: trimmed off when saved.
                    let end = x(doc.totalSamples)
                    ctx.fill(Path(CGRect(x: end, y: 0, width: size.width - end, height: size.height)), with: .color(.black.opacity(0.35)))
                    if doc.looping {
                        let ls = x(doc.loopStartSample)
                        ctx.fill(Path(CGRect(x: ls, y: 0, width: max(0, end - ls), height: size.height)), with: .color(.accentColor.opacity(0.12)))
                        marker(ctx, at: ls, height: size.height, color: .accentColor, label: "Loop")
                    }
                    marker(ctx, at: end, height: size.height, color: .orange, label: "End")
                    if let pos = player.position {
                        ctx.fill(Path(CGRect(x: x(pos) - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let sample = Int((g.location.x / width) * CGFloat(length)).clamped(0, length)
                let startX = g.startLocation.x
                if doc.looping, abs(startX - x(doc.loopStartSample)) < 8 {
                    let v = min(sample, max(doc.totalSamples - 1, 0))
                    if v != doc.loopStartSample { doc.loopStartSample = v; box.audioChanged() }
                } else if abs(startX - x(doc.totalSamples)) < 8 {
                    let v = max(sample, doc.looping ? doc.loopStartSample + 1 : 1)
                    if v != doc.totalSamples { doc.totalSamples = v; box.audioChanged() }
                } else if g.translation == .zero {
                    player.play(doc, track: previewTrack, from: sample)
                }
            })
            .help("Click to play from a point. Drag the blue Loop marker or the orange End marker to move them.")
        }
        .frame(height: 180)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func drawWaveform(_ ctx: GraphicsContext, size: CGSize) {
        let lanes = box.peaks
        guard !lanes.isEmpty else { return }
        let laneHeight = size.height / CGFloat(lanes.count)
        let columns = max(1, Int(size.width))
        for (lane, peaks) in lanes.enumerated() where !peaks.isEmpty {
            let mid = laneHeight * (CGFloat(lane) + 0.5)
            var path = Path()
            for col in 0..<columns {
                let lo = peaks.count * col / columns, hi = max(lo + 1, peaks.count * (col + 1) / columns)
                var mn = Int16.max, mx = Int16.min
                for p in peaks[lo..<min(hi, peaks.count)] { mn = min(mn, p.0); mx = max(mx, p.1) }
                let top = mid - CGFloat(mx) / 32768 * laneHeight / 2
                let bottom = mid - CGFloat(mn) / 32768 * laneHeight / 2
                path.addRect(CGRect(x: CGFloat(col), y: top, width: 1, height: max(1, bottom - top)))
            }
            ctx.fill(path, with: .color(.secondary))
        }
    }

    private func marker(_ ctx: GraphicsContext, at x: CGFloat, height: CGFloat, color: Color, label: String) {
        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: height)), with: .color(color))
        ctx.draw(Text(label).font(.caption2.bold()).foregroundColor(color), at: CGPoint(x: x + 4, y: 8), anchor: .leading)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                if player.isPlaying { player.stop() } else { player.play(doc, track: previewTrack, from: player.position ?? 0) }
            } label: { Image(systemName: player.isPlaying ? "stop.fill" : "play.fill").frame(width: 16) }
            Button("Play Loop Seam") {
                player.play(doc, track: previewTrack, from: max(doc.loopStartSample, doc.totalSamples - Int(rate * 3)))
            }
            .disabled(!doc.looping)
            .help("Plays the last 3 seconds before the end and on through the jump back to the loop start, listen for a click or a skipped beat.")
            Text(player.position.map { formatTime(Double($0) / rate, precise: true) } ?? "--:--.---")
                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
            if doc.tracks.count > 1 {
                Picker("Preview", selection: $previewTrack) {
                    ForEach(doc.tracks.indices, id: \.self) { Text("Track \($0)").tag($0) }
                }
                .fixedSize()
                .help("Multi-track streams hold alternative layers (e.g. an underwater mix) that the game switches between, so each one is previewed on its own.")
            }
            if let error = player.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    // MARK: Loop / length

    private var loopSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Loop", isOn: Binding(get: { doc.looping }, set: { doc.looping = $0; box.audioChanged() }))
            if doc.looping {
                sampleField("Loop start", value: doc.loopStartSample) { doc.loopStartSample = $0.clamped(0, max(doc.totalSamples - 1, 0)); box.audioChanged() }
            }
            sampleField("End", value: doc.totalSamples) {
                doc.totalSamples = $0.clamped(doc.looping ? doc.loopStartSample + 1 : 1, doc.channelSamples.first?.count ?? 0)
                box.audioChanged()
            }
            if doc.loopAlignmentPadding > 0 {
                Text("The game loops from the start of an 8 KiB block, so saving adds \(formatTime(Double(doc.loopAlignmentPadding) / rate, precise: true)) of silence before the song to line the loop start up with one. Every retail track's loop is aligned this way.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .leading)
            }
        }
    }

    private func sampleField(_ label: String, value: Int, commit: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField("", value: Binding(get: { value }, set: commit), format: .number.grouping(.never))
                .frame(width: 100)
            Text("samples (\(formatTime(Double(value) / rate, precise: true)))").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Tracks

    private var trackSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracks").font(.headline)
            ForEach(doc.tracks.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Track \(i), channels \(doc.tracks[i].channelIndices.map(String.init).joined(separator: ", "))").font(.caption)
                    HStack {
                        Text("Volume").font(.caption).frame(width: 50, alignment: .leading)
                        Slider(value: Binding(get: { Double(doc.tracks[i].volume) }, set: { doc.tracks[i].volume = UInt8($0); box.edited() }), in: 0...127)
                            .frame(width: 160)
                        Text("\(doc.tracks[i].volume)").font(.caption.monospacedDigit()).frame(width: 28)
                    }
                    HStack {
                        Text("Pan").font(.caption).frame(width: 50, alignment: .leading)
                        Slider(value: Binding(get: { Double(doc.tracks[i].pan) }, set: { doc.tracks[i].pan = UInt8($0); box.edited() }), in: 0...127)
                            .frame(width: 160)
                        Text(doc.tracks[i].pan == 64 ? "C" : doc.tracks[i].pan < 64 ? "L\(64 - Int(doc.tracks[i].pan))" : "R\(Int(doc.tracks[i].pan) - 64)")
                            .font(.caption.monospacedDigit()).frame(width: 28)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func replaceAudio() {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = AudioFileImport.contentTypes }) { url in
            guard let url else { return }
            do {
                let audio = try AudioFileImport.load(url, sampleRate: 32000)
                player.stop()
                doc.replaceAudio(channels: audio.channels, sampleRate: audio.sampleRate)
                previewTrack = 0
                box.audioChanged(samplesChanged: true)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func saveAsBRSTM(_ source: String) {
        PanelPresenter.saveFile(configure: {
            $0.nameFieldStringValue = (source as NSString).deletingPathExtension
            if let type = UTType(filenameExtension: "brstm") { $0.allowedContentTypes = [type] }
        }) { url in
            guard let url else { return }
            do { try doc.serialize().write(to: url, options: .atomic) }
            catch { importError = error.localizedDescription }
        }
    }

    private func exportWAV() {
        PanelPresenter.saveFile(configure: {
            $0.nameFieldStringValue = "track"
            if let wavType = UTType(filenameExtension: "wav") { $0.allowedContentTypes = [wavType] }
        }) { url in
            guard let url else { return }
            try? doc.exportWAV().write(to: url, options: .atomic)
        }
    }

    private func formatTime(_ seconds: Double, precise: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        let base = String(format: "%d:%02d", whole / 60, whole % 60)
        return precise ? base + String(format: ".%03d", Int((seconds - Double(whole)) * 1000)) : base
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}

/// Plays one track of a stream the way the game will: from a start point to the end marker, then
/// (if looping) from the loop start to the end forever. `position` is the sample being heard.
@MainActor final class BRSTMPreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var start = 0, introLength = 0, loopStart = 0, loopLength = 0
    private var playGeneration = 0

    init() {
        engine.attach(node)
    }

    var position: Int? {
        guard isPlaying, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return nil }
        let played = Int(p.sampleTime)
        if played < introLength { return start + played }
        return loopLength > 0 ? loopStart + (played - introLength) % loopLength : start + introLength
    }

    func play(_ doc: BRSTMDocument, track: Int, from: Int) {
        stop()
        playGeneration += 1
        let channels = doc.tracks.indices.contains(track) ? doc.tracks[track].channelIndices.map(Int.init).filter { $0 < doc.channelCount } : Array(0..<min(2, doc.channelCount))
        guard !channels.isEmpty, doc.totalSamples > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(doc.sampleRate), channels: AVAudioChannelCount(channels.count)) else { return }
        let gain = doc.tracks.indices.contains(track) ? Float(doc.tracks[track].volume) / 127 : 1
        func buffer(_ range: Range<Int>) -> AVAudioPCMBuffer? {
            guard !range.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else { return nil }
            b.frameLength = AVAudioFrameCount(range.count)
            var scale = gain / 32768
            for (out, ch) in channels.enumerated() {
                let dst = b.floatChannelData![out]
                dst.update(repeating: 0, count: range.count)
                doc.channelSamples[ch].withUnsafeBufferPointer { src in
                    let n = min(range.count, src.count - range.lowerBound)
                    guard n > 0 else { return }
                    vDSP_vflt16(src.baseAddress! + range.lowerBound, 1, dst, 1, vDSP_Length(n))
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(n))
                }
            }
            return b
        }
        let end = min(doc.totalSamples, doc.channelSamples[channels[0]].count)
        start = max(0, min(from, end - 1))
        introLength = end - start
        loopStart = doc.loopStartSample
        loopLength = doc.looping ? max(0, end - loopStart) : 0

        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { errorMessage = "Couldn't start audio: \(error.localizedDescription)"; return }
        if let intro = buffer(start..<end) { node.scheduleBuffer(intro) }
        if loopLength > 0, let loop = buffer(loopStart..<end) {
            node.scheduleBuffer(loop, at: nil, options: .loops)
        } else if let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) {
            // A silent frame whose playback marks the end. `node.stop()` also fires this, so the
            // generation check keeps a stale callback from stopping the next play.
            tail.frameLength = 1
            let generation = playGeneration
            node.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in if self?.playGeneration == generation { self?.stop() } }
            }
        }
        node.play()
        isPlaying = true
        errorMessage = nil
    }

    func stop() {
        node.stop()
        isPlaying = false
    }
}
