// BRSTM reader/writer/encoder check against every .brstm on a retail Mario Kart Wii disc.
//
// 1. Open + save with nothing edited must reproduce each file byte for byte. The ADPC seek table
//    and loop context are rebuilt from the *decoded* samples, so this also proves the decoder
//    reproduces the hardware's history at every block boundary on real data.
// 2. Re-encoding (as after an edit) must decode back to exactly what the encoder said it would,
//    and stay close to the source audio.
// 3. A loop start off a block boundary is padded onto one, as retail's always are.
//
//   swiftc -O -o /tmp/brstmcheck \
//     "Revolution IDE/Core/"{BinaryIO,DiscModel,WiiDisc,Crypto,ClusterCrypto,KeyManager,FSTBuilder}.swift \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRSTM,AudioFileImport}.swift \
//     Tests/BRSTMCheck/main.swift
//   /tmp/brstmcheck <iso> <common-key>

import Foundation
var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL \(what())") } }

let disc = try WiiDisc(url: URL(fileURLWithPath: CommandLine.arguments[1]),
                       commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))), koreanKey: nil)
var files: [(String, Data)] = []
func walk(_ n: DiscNode) {
    if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix(".brstm"), let d = try? disc.readFile(node: n) { files.append((n.name, d)) }
}
walk(disc.root)
check(files.count > 100, "found \(files.count) retail .brstm files")

var identical = 0
for (name, data) in files {
    guard let doc = try? BRSTMDocument.parse(data) else { check(false, "\(name) parses"); continue }
    let out = doc.serialize()
    if out == data { identical += 1; continue }
    let at = zip(out, data).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(out.count, data.count)
    check(false, "\(name) round trip differs at 0x\(String(at, radix: 16)) (\(out.count) vs \(data.count) bytes)")
}
print("\(identical)/\(files.count) retail files reproduced byte for byte")

func snr(_ a: [Int16], _ b: [Int16]) -> Double {
    var sig = 0.0, noise = 0.0
    for (x, y) in zip(a, b) { sig += Double(x) * Double(x); noise += Double(Int(x) - Int(y)) * Double(Int(x) - Int(y)) }
    return noise == 0 ? .infinity : 10 * log10(sig / noise)
}

for name in ["n_Circuit32_n.brstm", "STRM_N_DESERT_N.brstm", "o_Start32_fan.brstm"] {
    guard let data = files.first(where: { $0.0 == name })?.1, let doc = try? BRSTMDocument.parse(data) else { check(false, "\(name) on disc"); continue }
    let source = doc.channelSamples
    doc.encoded = nil
    let t0 = Date()
    let out = doc.serialize()
    let secs = Date().timeIntervalSince(t0)
    guard let back = try? BRSTMDocument.parse(out), let e = doc.encoded else { check(false, "\(name) re-encoded file parses"); continue }
    check(back.channelSamples == e.decoded, "\(name): decoder hears exactly what the encoder predicted")
    check(back.codec == doc.codec && back.looping == doc.looping && back.loopStartSample == doc.loopStartSample
          && back.totalSamples == doc.totalSamples && back.channelCount == doc.channelCount, "\(name): header survives re-encode")
    let worst = zip(source, back.channelSamples).map { snr($0, $1) }.min() ?? 0
    check(worst > 20, "\(name): re-encode SNR \(String(format: "%.1f", worst)) dB")
    print(String(format: "%@: re-encoded %.1fs of audio x%d ch in %.2fs, worst-channel SNR %.1f dB, %d -> %d bytes",
                 name, doc.durationSeconds, doc.channelCount, secs, worst, data.count, out.count))
}

// The frame search on its own: audio that came out of an ADPCM encoder is exactly representable
// with that encoder's coefficients, so a search that really finds the best frame recovers it.
if let data = files.first(where: { $0.0 == "n_Circuit32_n.brstm" })?.1, let doc = try? BRSTMDocument.parse(data) {
    let src = Array(doc.channelSamples[0].prefix(32000 * 10))
    let (_, out) = DSPADPCMEncoder.encode(src, coefficients: doc.adpcmParams[0].coefficients)
    let s = snr(src, out)
    check(s > 60, "retail audio re-encoded with retail's own coefficients: SNR \(String(format: "%.1f", s)) dB")
    print(String(format: "frame search with retail coefficients: %.1f dB", s))
}
// Real uncompressed source: retail's PCM16 streams, encoded to ADPCM.
for (name, data) in files where name.hasPrefix("o_") {
    guard let doc = try? BRSTMDocument.parse(data), doc.codec == .pcm16 else { continue }
    let src = doc.channelSamples[0]
    let (_, out) = DSPADPCMEncoder.encode(src, coefficients: DSPADPCMEncoder.coefficients(for: src))
    let s = snr(src, out)
    check(s > 20, "\(name) PCM16 source -> ADPCM SNR \(String(format: "%.1f", s)) dB")
    print(String(format: "%@ PCM16 -> ADPCM: %.1f dB", name, s))
}

// Loop start off a block boundary.
if let data = files.first(where: { $0.0 == "n_Circuit32_n.brstm" })?.1, let doc = try? BRSTMDocument.parse(data) {
    doc.loopStartSample = 100_000
    doc.encoded = nil
    let pad = doc.loopAlignmentPadding
    let back = try BRSTMDocument.parse(doc.serialize())
    check(back.loopStartSample % 14336 == 0 && back.loopStartSample == 100_000 + pad, "loop start padded onto a block: \(back.loopStartSample)")
    check(back.totalSamples == doc.totalSamples + pad, "padding adds exactly \(pad) samples")
    check(back.channelSamples[0].prefix(pad).allSatisfy { abs(Int($0)) < 64 }, "padding decodes as silence")
}

// "BRSTM from Audio": a real song as a 44.1 kHz AAC file (what people actually import), decoded,
// resampled to 32 kHz and written as a new stream.
if let data = files.first(where: { $0.0 == "n_Circuit32_n.brstm" })?.1, let doc = try? BRSTMDocument.parse(data) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brstmcheck-\(getpid())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wav = dir.appendingPathComponent("song.wav"), m4a = dir.appendingPathComponent("song.m4a")
    try doc.exportWAV().write(to: wav)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    p.arguments = ["-f", "m4af", "-d", "aac@44100", wav.path, m4a.path]
    try p.run(); p.waitUntilExit()
    let audio = try AudioFileImport.load(m4a, sampleRate: 32000)
    check(audio.channels.count == 2 && audio.sampleRate == 32000, "AAC import: \(audio.channels.count) ch at \(audio.sampleRate) Hz")
    let drift = abs(Double(audio.channels[0].count - doc.totalSamples)) / Double(doc.totalSamples)
    check(drift < 0.01, "AAC import length \(audio.channels[0].count) vs source \(doc.totalSamples)")
    let made = BRSTMDocument()
    made.replaceAudio(channels: audio.channels, sampleRate: audio.sampleRate)
    made.loopStartSample = doc.loopStartSample + 1234
    let back = try BRSTMDocument.parse(made.serialize())
    check(back.codec == .adpcm && back.looping && back.channelCount == 2 && back.tracks.count == 1
          && back.tracks[0].channelIndices == [0, 1] && back.loopStartSample % 14336 == 0,
          "new BRSTM from audio: ADPCM, looping, one stereo track, loop \(back.loopStartSample)")
    try? FileManager.default.removeItem(at: dir)
}

print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
