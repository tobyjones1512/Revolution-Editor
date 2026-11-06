import Foundation

/// Binary Revolution STream. Mario Kart Wii's (and Super Smash Bros. Brawl's) streamed
/// background-music format. Container/field layout verified against the community
/// documentation and, for the writer, byte-for-byte against every `.brstm` on a retail Mario Kart
/// Wii disc (see `Tests/BRSTMCheck`). The GC/Wii "DSP-ADPCM" codec itself, a fixed piece of Wii
/// audio hardware behavior, not something BRSTM invented, was verified against vgmstream's
/// `ngc_dsp_decoder.c` (github.com/vgmstream/vgmstream, ISC license); this is
/// an original Swift implementation of that same public algorithm, not a translation of that file.
///
/// Editable: `channelSamples`/loop/length/track mix are the document; `serialize()` writes them
/// back, re-encoding only when the audio actually changed (`encoded` caches the file's own bytes,
/// so opening and saving a retail file reproduces it exactly).
nonisolated enum BRSTMCodec: UInt8 {
    case pcm8 = 0, pcm16 = 1, adpcm = 2

    /// Every retail stream uses 8 KiB blocks: 14336 ADPCM samples (1024 8-byte frames of 14), or
    /// 4096 PCM16 samples.
    var blockSamples: Int { self == .pcm16 ? 4096 : 14336 }
}

/// The 16 predictor coefficients (8 pairs) plus per-channel initial/loop decoder state, read from
/// the file's "ADPCM Parameters Set", only present when `BRSTMDocument.codec == .adpcm`.
nonisolated struct BRSTMADPCMChannelParams {
    var coefficients: [Int16] = Array(repeating: 0, count: 16)
    var gain: UInt16 = 0
    var initialPredictorScale: UInt16 = 0
    var initialHist1: Int16 = 0
    var initialHist2: Int16 = 0
    var loopPredictorScale: UInt16 = 0
    var loopHist1: Int16 = 0
    var loopHist2: Int16 = 0
}

nonisolated struct BRSTMTrack {
    var volume: UInt8 = 127
    var pan: UInt8 = 64
    var channelIndices: [UInt8] = []
}

/// The audio exactly as it goes into the file: sample positions in *file* coordinates (after any
/// loop-alignment padding `BRSTMDocument.encode` adds), one continuous encoded stream per channel,
/// and what the game's decoder will reconstruct from it, the ADPC seek table and the loop
/// context are both taken from `decoded`, since that's the history the hardware actually has.
nonisolated struct BRSTMEncoded {
    var codec: BRSTMCodec
    var looping: Bool
    var loopStart: Int
    var totalSamples: Int
    var channels: [Data]
    var coefficients: [[Int16]]
    var decoded: [[Int16]]
    /// The ADPC entries as read from a file (block-major, then channel; hist1, hist2). Retail's are
    /// Nintendo's *source* PCM history, which can't be recovered from the decoded audio, so they're
    /// carried through untouched; a fresh encode (`nil`) takes them from `decoded` instead.
    var seekTable: Data? = nil
}

nonisolated final class BRSTMDocument {
    var codec: BRSTMCodec = .adpcm
    var looping = false
    var sampleRate = 32000
    var loopStartSample = 0
    var totalSamples = 0
    var tracks: [BRSTMTrack] = []
    /// One entry per channel (empty for PCM8/PCM16 streams, which need no predictor state).
    var adpcmParams: [BRSTMADPCMChannelParams] = []
    /// Decoded (PCM8/16: widened/passthrough; ADPCM: actually decoded) 16-bit samples, one array
    /// per channel. Can be longer than `totalSamples` after a trim, so the trim can be undone.
    var channelSamples: [[Int16]] = []
    /// The file's audio as last encoded, `nil` once the samples, loop or length change, which is
    /// what makes the next `serialize()` re-encode. Track volume/pan don't touch it.
    var encoded: BRSTMEncoded?

    var channelCount: Int { channelSamples.count }
    var durationSeconds: Double { sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : 0 }

    /// How many samples of silence saving will put in front of the audio so the loop start lands
    /// on a block boundary. Every retail loop starts on one, and BrawlBox pads the same way.
    var loopAlignmentPadding: Int { Self.loopAlignmentPadding(codec: codec, looping: looping, loopStart: loopStartSample) }

    private static func loopAlignmentPadding(codec: BRSTMCodec, looping: Bool, loopStart: Int) -> Int {
        guard looping else { return 0 }
        let block = (codec == .pcm16 ? BRSTMCodec.pcm16 : .adpcm).blockSamples
        return (block - loopStart % block) % block
    }

    /// Replaces the audio wholesale (e.g. an imported song): loops the whole thing by default and
    /// rebuilds the track table as stereo pairs, keeping each surviving track's volume/pan.
    func replaceAudio(channels: [[Int16]], sampleRate: Int) {
        channelSamples = channels
        self.sampleRate = sampleRate
        totalSamples = channels.first?.count ?? 0
        looping = true
        loopStartSample = 0
        if codec == .pcm8 { codec = .adpcm }
        tracks = stride(from: 0, to: channels.count, by: 2).enumerated().map { i, c in
            var t = i < tracks.count ? tracks[i] : BRSTMTrack()
            t.channelIndices = (c..<min(c + 2, channels.count)).map { UInt8($0) }
            return t
        }
        encoded = nil
    }

    // MARK: Parse

    static func parse(_ data: Data) throws -> BRSTMDocument {
        guard data.count >= 0x40, data.asciiString(at: 0, length: 4) == "RSTM" else {
            throw WSError.badStructure("Not a BRSTM file (missing 'RSTM' magic).")
        }
        guard data.be16(0x04) == 0xFEFF else {
            throw WSError.badStructure("Little-endian BRSTM files aren't supported (Mario Kart Wii doesn't produce them).")
        }
        let headOffset = Int(data.be32(0x10))
        guard headOffset > 0, headOffset + 0x1C <= data.count, data.asciiString(at: headOffset, length: 4) == "HEAD" else {
            throw WSError.badStructure("BRSTM missing or malformed HEAD section.")
        }
        let dataSectionOffset = Int(data.be32(0x20))
        guard dataSectionOffset > 0, dataSectionOffset + 0x0C <= data.count, data.asciiString(at: dataSectionOffset, length: 4) == "DATA" else {
            throw WSError.badStructure("BRSTM missing or malformed DATA section.")
        }

        // "Offsets are relative to 0x08 of this header", i.e. every DataRef *value* inside HEAD
        // (including the nested ones in the Track/Channel tables) is added to headBase to get an
        // absolute file offset. The three top-level DataRefs themselves sit right at headBase --
        // verified against a real Mario Kart Wii .brstm's raw bytes (headBase+0x00/+0x08/+0x10),
        // not the file-relative 0x08/0x10/0x18 the section-layout table's own column literally
        // says (that column is relative to the section start, which headBase has already offset
        // past by skipping the magic+size).
        let headBase = headOffset + 8
        func dataRef(_ at: Int) -> Int { headBase + Int(data.be32(at + 4)) }

        let streamInfo = dataRef(headBase + 0x00)
        let trackTable = dataRef(headBase + 0x08)
        let channelTable = dataRef(headBase + 0x10)
        guard streamInfo + 0x34 <= data.count else { throw WSError.badStructure("BRSTM Stream Data Info out of range.") }

        let doc = BRSTMDocument()
        guard let codec = BRSTMCodec(rawValue: data.u8(streamInfo)) else {
            throw WSError.badStructure("Unknown BRSTM codec byte \(data.u8(streamInfo)).")
        }
        doc.codec = codec
        doc.looping = data.u8(streamInfo + 1) != 0
        let channelCount = Int(data.u8(streamInfo + 2))
        doc.sampleRate = (Int(data.u8(streamInfo + 3)) << 16) | (Int(data.u8(streamInfo + 4)) << 8) | Int(data.u8(streamInfo + 5))
        doc.loopStartSample = Int(data.be32(streamInfo + 0x08))
        doc.totalSamples = Int(data.be32(streamInfo + 0x0C))
        // An absolute file offset (always DATA + 0x20 on retail files), not one relative to DATA.
        let audioDataOffset = Int(data.be32(streamInfo + 0x10))
        let blockCount = Int(data.be32(streamInfo + 0x14))
        let blockSize = Int(data.be32(streamInfo + 0x18))
        let blockSamples = Int(data.be32(streamInfo + 0x1C))
        let finalBlockSize = Int(data.be32(streamInfo + 0x20))
        let finalBlockSamples = Int(data.be32(streamInfo + 0x24))
        let finalBlockSizePadded = Int(data.be32(streamInfo + 0x28))

        guard channelCount > 0, channelCount < 32 else { throw WSError.badStructure("Implausible BRSTM channel count.") }
        // `doc.totalSamples` feeds `reserveCapacity` below, and `blockCount` bounds the decode
        // loop, both are raw 32-bit header fields with no inherent relation to the file's actual
        // size, so a corrupt/malicious file claiming an implausibly huge value would otherwise
        // trigger a huge up-front allocation (or a very long, pointless decode loop) before the
        // per-block bounds checks below ever get a chance to reject it. `blockCount` in particular
        // is only ever a few thousand for any real file (a several-minute track at the smallest
        // real block size is still under that); `totalSamples` is capped by what could plausibly
        // fit in this file at 1 bit/sample (ADPCM's smallest real encoding).
        guard doc.totalSamples >= 0, doc.totalSamples <= data.count * 8 else {
            throw WSError.badStructure("Implausible BRSTM total sample count.")
        }
        guard blockCount >= 0, blockCount <= 1_000_000 else {
            throw WSError.badStructure("Implausible BRSTM block count.")
        }

        // MARK: Track Table
        if trackTable > 0, trackTable + 4 <= data.count {
            let trackCount = Int(data.u8(trackTable))
            let extended = data.u8(trackTable + 1) != 0
            for t in 0..<trackCount {
                let refBase = trackTable + 4 + t * 8
                guard refBase + 8 <= data.count else { break }
                let infoOffset = dataRef(refBase)
                guard infoOffset >= 0, infoOffset < data.count else { continue }
                var track = BRSTMTrack()
                let channelCountFieldOffset: Int
                if extended, infoOffset + 9 <= data.count {
                    track.volume = data.u8(infoOffset)
                    track.pan = data.u8(infoOffset + 1)
                    channelCountFieldOffset = infoOffset + 8
                } else {
                    channelCountFieldOffset = infoOffset
                }
                guard channelCountFieldOffset < data.count else { doc.tracks.append(track); continue }
                let n = Int(data.u8(channelCountFieldOffset))
                for c in 0..<n {
                    let idxOffset = channelCountFieldOffset + 1 + c
                    guard idxOffset < data.count else { break }
                    track.channelIndices.append(data.u8(idxOffset))
                }
                doc.tracks.append(track)
            }
        }

        // MARK: Channel Table + ADPCM Parameters (double DataRef indirection per the format)
        if codec == .adpcm, channelTable > 0, channelTable + 4 <= data.count {
            for c in 0..<channelCount {
                let refBase = channelTable + 4 + c * 8
                guard refBase + 8 <= data.count else { doc.adpcmParams.append(BRSTMADPCMChannelParams()); continue }
                let indirectOffset = dataRef(refBase)
                guard indirectOffset >= 0, indirectOffset + 8 <= data.count else { doc.adpcmParams.append(BRSTMADPCMChannelParams()); continue }
                let paramsValue = Int(data.be32(indirectOffset + 4))
                guard paramsValue != 0 else { doc.adpcmParams.append(BRSTMADPCMChannelParams()); continue }
                let paramsOffset = headBase + paramsValue
                guard paramsOffset + 0x2E <= data.count else { doc.adpcmParams.append(BRSTMADPCMChannelParams()); continue }
                var p = BRSTMADPCMChannelParams()
                for i in 0..<16 { p.coefficients[i] = data.beInt16(paramsOffset + i * 2) }
                p.gain = data.be16(paramsOffset + 0x20)
                p.initialPredictorScale = data.be16(paramsOffset + 0x22)
                p.initialHist1 = data.beInt16(paramsOffset + 0x24)
                p.initialHist2 = data.beInt16(paramsOffset + 0x26)
                p.loopPredictorScale = data.be16(paramsOffset + 0x28)
                p.loopHist1 = data.beInt16(paramsOffset + 0x2A)
                p.loopHist2 = data.beInt16(paramsOffset + 0x2C)
                doc.adpcmParams.append(p)
            }
        }

        // MARK: Decode audio. Data is stored "channel 0 block 0, channel 1 block 0, channel 0
        // block 1, ..." (block-interleaved, not sample-interleaved like a WAV).
        doc.channelSamples = Array(repeating: [], count: channelCount)
        var streams = Array(repeating: Data(), count: channelCount)
        var complete = true
        for ch in 0..<channelCount {
            var hist1: Int32 = codec == .adpcm && ch < doc.adpcmParams.count ? Int32(doc.adpcmParams[ch].initialHist1) : 0
            var hist2: Int32 = codec == .adpcm && ch < doc.adpcmParams.count ? Int32(doc.adpcmParams[ch].initialHist2) : 0
            let coefs = ch < doc.adpcmParams.count ? doc.adpcmParams[ch].coefficients : []
            var samples: [Int16] = []
            samples.reserveCapacity(doc.totalSamples)

            for block in 0..<max(blockCount, 0) {
                let isFinal = block == blockCount - 1
                let thisBlockSize = isFinal ? finalBlockSize : blockSize
                let thisBlockSamples = isFinal ? finalBlockSamples : blockSamples
                guard thisBlockSize > 0, thisBlockSamples > 0 else { continue }
                // Every block before the last is `blockSize` per channel; only the last one's
                // channels are `finalBlockSizePadded` apart.
                let blockOffset = audioDataOffset + block * channelCount * blockSize
                    + ch * (isFinal ? finalBlockSizePadded : blockSize)
                guard blockOffset >= 0, blockOffset + thisBlockSize <= data.count else { complete = false; break }
                streams[ch].append(data.subdata(in: blockOffset..<(blockOffset + thisBlockSize)))

                switch codec {
                case .pcm16:
                    var i = 0
                    while i < thisBlockSamples, blockOffset + i * 2 + 2 <= data.count {
                        samples.append(data.beInt16(blockOffset + i * 2))
                        i += 1
                    }
                case .pcm8:
                    var i = 0
                    while i < thisBlockSamples, blockOffset + i < data.count {
                        samples.append(Int16(data.beInt8(blockOffset + i)) << 8)
                        i += 1
                    }
                case .adpcm:
                    BRSTMDocument.decodeADPCMBlock(data, at: blockOffset, byteCount: thisBlockSize, sampleCount: thisBlockSamples,
                                                     coefficients: coefs, hist1: &hist1, hist2: &hist2, into: &samples)
                }
            }
            doc.channelSamples[ch] = samples
        }
        if complete, codec != .pcm8, doc.channelSamples.allSatisfy({ $0.count == doc.totalSamples }) {
            doc.encoded = BRSTMEncoded(codec: codec, looping: doc.looping, loopStart: doc.loopStartSample,
                                       totalSamples: doc.totalSamples, channels: streams,
                                       coefficients: doc.adpcmParams.map(\.coefficients), decoded: doc.channelSamples)
            let adpcOffset = Int(data.be32(0x18)), entries = blockCount * channelCount * 4
            if codec == .adpcm, adpcOffset > 0, adpcOffset + 8 + entries <= data.count {
                doc.encoded?.seekTable = data.subdata(in: (adpcOffset + 8)..<(adpcOffset + 8 + entries))
            }
        }
        return doc
    }

    /// Decodes one GC/Wii DSP-ADPCM frame-group (a "block"): each 8-byte frame is a 1-byte
    /// header (scale in the low nibble, predictor-coefficient-pair index in the high nibble)
    /// followed by 14 signed 4-bit sample nibbles, high nibble of each byte decoded first.
    private static func decodeADPCMBlock(_ data: Data, at blockOffset: Int, byteCount: Int, sampleCount: Int,
                                          coefficients: [Int16], hist1: inout Int32, hist2: inout Int32,
                                          into samples: inout [Int16]) {
        var produced = 0
        var frameStart = blockOffset
        let blockEnd = blockOffset + byteCount
        while produced < sampleCount, frameStart < blockEnd {
            let header = data.u8(frameStart)
            let scale: Int32 = 1 << Int32(header & 0x0F)
            var coefIndex = Int(header >> 4)
            if coefIndex > 7 { coefIndex = 7 } // matches every real decoder: clamp rather than trust bad data
            let coef1 = coefIndex * 2 < coefficients.count ? Int32(coefficients[coefIndex * 2]) : 0
            let coef2 = coefIndex * 2 + 1 < coefficients.count ? Int32(coefficients[coefIndex * 2 + 1]) : 0

            let nibbleBytes = min(7, blockEnd - frameStart - 1)
            var nibbleIndex = 0
            let framesSamplesRemaining = min(14, sampleCount - produced)
            while nibbleIndex < framesSamplesRemaining, nibbleIndex / 2 < nibbleBytes {
                let byte = data.u8(frameStart + 1 + nibbleIndex / 2)
                let rawNibble = (nibbleIndex % 2 == 0) ? (byte >> 4) : (byte & 0x0F)
                var signedNibble = Int32(rawNibble)
                if signedNibble >= 8 { signedNibble -= 16 }

                var sample = (signedNibble * scale) << 11
                sample = (sample + 1024 + coef1 * hist1 + coef2 * hist2) >> 11
                let clamped = Int16(max(-32768, min(32767, sample)))
                samples.append(clamped)

                hist2 = hist1
                hist1 = Int32(clamped)
                nibbleIndex += 1
                produced += 1
            }
            frameStart += 8
        }
    }

    // MARK: Encode

    /// The file-ready audio for the current samples/loop/length, reusing `encoded` when nothing
    /// that affects it changed.
    @discardableResult
    func encode() -> BRSTMEncoded {
        if let encoded { return encoded }
        let result = Self.encode(channelSamples, codec: codec, looping: looping, loopStart: loopStartSample, totalSamples: totalSamples)
        encoded = result
        return result
    }

    /// Pure, so an editor can run it off the main thread on a snapshot of the document.
    static func encode(_ channelSamples: [[Int16]], codec: BRSTMCodec, looping: Bool, loopStart loopStartSample: Int, totalSamples: Int) -> BRSTMEncoded {
        let outCodec: BRSTMCodec = codec == .pcm16 ? .pcm16 : .adpcm
        let pad = loopAlignmentPadding(codec: codec, looping: looping, loopStart: loopStartSample)
        let length = min(totalSamples, channelSamples.map(\.count).min() ?? 0)
        let input = channelSamples.map { Array(repeating: Int16(0), count: pad) + $0.prefix(length) }
        var channels = Array(repeating: Data(), count: input.count)
        var coefficients = Array(repeating: [Int16](), count: input.count)
        var decoded = input
        if outCodec == .adpcm {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: input.count) { ch in
                let coefs = DSPADPCMEncoder.coefficients(for: input[ch])
                let (bytes, out) = DSPADPCMEncoder.encode(input[ch], coefficients: coefs)
                lock.lock(); channels[ch] = bytes; coefficients[ch] = coefs; decoded[ch] = out; lock.unlock()
            }
        } else {
            for (ch, samples) in input.enumerated() {
                let w = MutableDataWriter()
                for s in samples { w.putInt16(s) }
                channels[ch] = w.data
            }
        }
        return BRSTMEncoded(codec: outCodec, looping: looping, loopStart: looping ? loopStartSample + pad : 0,
                            totalSamples: pad + length, channels: channels, coefficients: coefficients, decoded: decoded)
    }

    // MARK: Write

    func serialize() -> Data {
        let e = encode()
        let channelCount = e.channels.count
        let isADPCM = e.codec == .adpcm
        let blockSamples = e.codec.blockSamples
        let blockSize = 0x2000
        let blockCount = max(1, (e.totalSamples + blockSamples - 1) / blockSamples)
        let finalSamples = e.totalSamples - (blockCount - 1) * blockSamples
        // A partial last frame counts only its header byte and the nibble bytes it uses.
        let finalSize = isADPCM ? finalSamples / 14 * 8 + (finalSamples % 14 == 0 ? 0 : 1 + (finalSamples % 14 + 1) / 2) : finalSamples * 2
        let finalPadded = (finalSize + 0x1F) & ~0x1F
        func align(_ v: Int, _ a: Int) -> Int { (v + a - 1) / a * a }

        // HEAD. Every DataRef value is relative to HEAD + 8; the layout (stream info, then the track
        // table and each track's info, then the channel table and each channel's info+params) is
        // exactly retail's, down to where the padding falls.
        let head = MutableDataWriter()
        func ref(_ offset: Int, marker: UInt32 = 0x0100_0000) { head.putU32(marker); head.putU32(UInt32(offset)) }
        let streamInfoOffset = 0x18
        let trackTableOffset = streamInfoOffset + 0x34
        let trackInfoStart = trackTableOffset + 4 + tracks.count * 8
        var trackInfoOffsets: [Int] = []
        var cursor = trackInfoStart
        for t in tracks { trackInfoOffsets.append(cursor); cursor += align(8 + 1 + t.channelIndices.count, 4) }
        let channelTableOffset = cursor
        let channelInfoSize = isADPCM ? 0x38 : 0x08
        let channelInfoStart = channelTableOffset + 4 + channelCount * 8

        head.putData(Data("HEAD".utf8)); head.putU32(0) // size patched below
        ref(streamInfoOffset); ref(trackTableOffset); ref(channelTableOffset)

        head.putU8(e.codec.rawValue); head.putU8(e.looping ? 1 : 0); head.putU8(UInt8(channelCount))
        head.putU8(UInt8((sampleRate >> 16) & 0xFF)); head.putU16(UInt16(sampleRate & 0xFFFF)); head.putU16(0)
        head.putU32(UInt32(e.loopStart)); head.putU32(UInt32(e.totalSamples))
        let headSectionSize = align(8 + channelInfoStart + channelCount * channelInfoSize, 0x20)
        let adpcSectionSize = isADPCM ? align(8 + blockCount * channelCount * 4, 0x20) : 0
        let dataSectionOffset = 0x40 + headSectionSize + adpcSectionSize
        head.putU32(UInt32(dataSectionOffset + 0x20))
        head.putU32(UInt32(blockCount)); head.putU32(UInt32(blockSize)); head.putU32(UInt32(blockSamples))
        head.putU32(UInt32(finalSize)); head.putU32(UInt32(finalSamples)); head.putU32(UInt32(finalPadded))
        head.putU32(isADPCM ? UInt32(blockSamples) : 0); head.putU32(isADPCM ? 4 : 0)

        head.putU8(UInt8(tracks.count)); head.putU8(1); head.putU16(0)
        for o in trackInfoOffsets { ref(o, marker: 0x0101_0000) } // retail marks extended track infos this way
        for t in tracks {
            head.putU8(t.volume); head.putU8(t.pan); head.putU16(0); head.putU32(0)
            head.putU8(UInt8(t.channelIndices.count)); t.channelIndices.forEach { head.putU8($0) }
            head.align(4)
        }

        head.putU8(UInt8(channelCount)); head.putU8(0); head.putU16(0)
        for c in 0..<channelCount { ref(channelInfoStart + c * channelInfoSize) }
        for c in 0..<channelCount {
            guard isADPCM else { ref(0); continue }
            let infoOffset = channelInfoStart + c * channelInfoSize
            ref(infoOffset + 8)
            let decoded = e.decoded[c]
            let stream = e.channels[c]
            func frameHeader(atSample s: Int) -> UInt16 { s / 14 * 8 < stream.count ? UInt16(stream[stream.startIndex + s / 14 * 8]) : 0 }
            func sample(_ i: Int) -> Int16 { i >= 0 && i < decoded.count ? decoded[i] : 0 }
            e.coefficients[c].forEach { head.putInt16($0) }
            head.putU16(0) // gain
            head.putU16(frameHeader(atSample: 0)); head.putInt16(0); head.putInt16(0)
            // Filled even when not looping (retail then describes sample 0).
            head.putU16(frameHeader(atSample: e.loopStart)); head.putInt16(sample(e.loopStart - 1)); head.putInt16(sample(e.loopStart - 2))
            head.putU16(0)
        }
        head.pad(to: headSectionSize)
        var headData = head.data
        headData.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(headSectionSize).bigEndian) { Data($0) })

        let w = MutableDataWriter()
        let fileSize = dataSectionOffset + 0x20 + (blockCount - 1) * blockSize * channelCount + finalPadded * channelCount
        w.putData(Data("RSTM".utf8)); w.putU16(0xFEFF); w.putU16(0x0100)
        w.putU32(UInt32(fileSize)); w.putU16(0x40); w.putU16(2)
        w.putU32(0x40); w.putU32(UInt32(headSectionSize))
        w.putU32(isADPCM ? UInt32(0x40 + headSectionSize) : 0); w.putU32(UInt32(adpcSectionSize))
        w.putU32(UInt32(dataSectionOffset)); w.putU32(UInt32(fileSize - dataSectionOffset))
        w.pad(to: 0x40)
        w.putData(headData)

        // ADPC: each channel's decoder history (hist1, hist2) at the start of every block, so the
        // player can seek to a block (i.e. the loop start) and resume decoding exactly.
        if isADPCM {
            let start = w.data.count
            w.putData(Data("ADPC".utf8)); w.putU32(UInt32(adpcSectionSize))
            if let table = e.seekTable, table.count == blockCount * channelCount * 4 { w.putData(table) } else { for b in 0..<blockCount {
                for c in 0..<channelCount {
                    let s = b * blockSamples
                    let d = e.decoded[c]
                    w.putInt16(s >= 1 ? d[s - 1] : 0); w.putInt16(s >= 2 ? d[s - 2] : 0)
                }
            } }
            w.pad(to: start + adpcSectionSize)
        }

        w.putData(Data("DATA".utf8)); w.putU32(UInt32(fileSize - dataSectionOffset)); w.putU32(0x18)
        w.pad(to: dataSectionOffset + 0x20)
        let bytesPerBlock = isADPCM ? blockSize : blockSamples * 2
        for b in 0..<blockCount {
            let isFinal = b == blockCount - 1
            for c in 0..<channelCount {
                let stream = e.channels[c]
                let from = stream.startIndex + b * bytesPerBlock
                let to = min(stream.endIndex, from + (isFinal ? finalSize : blockSize))
                let blockStart = w.data.count
                if from < to { w.putData(stream[from..<to]) }
                w.pad(to: blockStart + (isFinal ? finalPadded : blockSize))
            }
        }
        return w.data
    }

    // MARK: Export

    /// Interleaved 16-bit PCM WAV of every channel (trimmed to `totalSamples`), for exporting the
    /// track outside the app.
    func exportWAV() -> Data {
        let channels = max(1, channelSamples.count)
        let frameCount = min(totalSamples, channelSamples.map(\.count).max() ?? 0)
        let bytesPerSample = 2
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataSize = frameCount * blockAlign

        let w = MutableDataWriter()
        func putLE32(_ v: UInt32) { w.putU32(v.byteSwapped) }
        func putLE16(_ v: UInt16) { w.putU16(v.byteSwapped) }

        w.putData(Data("RIFF".utf8))
        putLE32(UInt32(36 + dataSize))
        w.putData(Data("WAVE".utf8))
        w.putData(Data("fmt ".utf8))
        putLE32(16)
        putLE16(1) // PCM
        putLE16(UInt16(channels))
        putLE32(UInt32(sampleRate))
        putLE32(UInt32(byteRate))
        putLE16(UInt16(blockAlign))
        putLE16(16) // bits per sample
        w.putData(Data("data".utf8))
        putLE32(UInt32(dataSize))

        for frame in 0..<frameCount {
            for ch in 0..<channels {
                let sample: Int16 = (ch < channelSamples.count && frame < channelSamples[ch].count) ? channelSamples[ch][frame] : 0
                putLE16(UInt16(bitPattern: sample))
            }
        }
        return w.data
    }
}

/// GC/Wii DSP-ADPCM encoder. The decoder is fixed hardware (see `decodeADPCMBlock`), so anything
/// it decodes is valid; quality comes from two choices this makes:
///
/// - The 8 predictor pairs: a generalized Lloyd (k-means) fit over 14-sample frames, where each
///   frame joins the pair with the least squared prediction error and each pair is re-solved as
///   the least-squares predictor of its frames, split 1 -> 2 -> 4 -> 8.
/// - Each frame's pair and scale: tried against the *decoded* history (closed loop), so the
///   rounding the hardware does is what gets minimized, not an idealized residual.
nonisolated enum DSPADPCMEncoder {
    private struct Stats {
        var r00 = 0.0, r01 = 0.0, r02 = 0.0, r11 = 0.0, r12 = 0.0, r22 = 0.0
        static func += (a: inout Stats, b: Stats) {
            a.r00 += b.r00; a.r01 += b.r01; a.r02 += b.r02; a.r11 += b.r11; a.r12 += b.r12; a.r22 += b.r22
        }
        func error(_ a1: Double, _ a2: Double) -> Double {
            r00 - 2 * a1 * r01 - 2 * a2 * r02 + a1 * a1 * r11 + 2 * a1 * a2 * r12 + a2 * a2 * r22
        }
        /// The least-squares predictor, kept inside the stable region (|a2| < 1, |a1| < 1 + a2).
        func solve() -> (Double, Double) {
            let eps = 1e-9 * (r11 + r22) + 1e-9
            let d11 = r11 + eps, d22 = r22 + eps
            let det = d11 * d22 - r12 * r12
            guard det > 0 else { return (0, 0) }
            var a1 = (r01 * d22 - r02 * r12) / det
            var a2 = (r02 * d11 - r01 * r12) / det
            a2 = max(-0.998, min(0.998, a2))
            a1 = max(-(1 + a2) * 0.998, min((1 + a2) * 0.998, a1))
            return (a1, a2)
        }
    }

    static func coefficients(for samples: [Int16]) -> [Int16] {
        let frameCount = (samples.count + 13) / 14
        // Training on at most ~40k frames (~17 s at 32 kHz) spread across the whole track keeps
        // this fast on long songs without favoring one section.
        let step = max(1, frameCount / 40_000)
        var frames: [Stats] = []
        frames.reserveCapacity(frameCount / step + 1)
        for f in stride(from: 0, to: frameCount, by: step) {
            var s = Stats()
            for n in (f * 14)..<min(f * 14 + 14, samples.count) {
                let x0 = Double(samples[n])
                let x1 = n >= 1 ? Double(samples[n - 1]) : 0
                let x2 = n >= 2 ? Double(samples[n - 2]) : 0
                s.r00 += x0 * x0; s.r01 += x0 * x1; s.r02 += x0 * x2
                s.r11 += x1 * x1; s.r12 += x1 * x2; s.r22 += x2 * x2
            }
            if s.r00 > 0 { frames.append(s) }
        }
        var total = Stats()
        frames.forEach { total += $0 }
        var pairs = [total.solve()]
        while pairs.count < 8 {
            pairs = pairs.flatMap { [($0.0 + 0.01, $0.1), ($0.0 - 0.01, $0.1)] }
            for _ in 0..<12 {
                var sums = Array(repeating: Stats(), count: pairs.count)
                for s in frames {
                    var best = 0, bestErr = Double.infinity
                    for (i, p) in pairs.enumerated() {
                        let e = s.error(p.0, p.1)
                        if e < bestErr { bestErr = e; best = i }
                    }
                    sums[best] += s
                }
                for i in pairs.indices where sums[i].r11 > 0 { pairs[i] = sums[i].solve() }
            }
        }
        return pairs.flatMap { [Int16(clamping: Int(($0.0 * 2048).rounded())), Int16(clamping: Int(($0.1 * 2048).rounded()))] }
    }

    /// The continuous frame stream for one channel (last frame zero-padded), plus exactly what
    /// the hardware will decode from it. Written against raw buffers with plain comparisons
    /// because this is the hot loop, and Debug builds (which don't inline `min`/`max` or elide
    /// array bounds checks) would otherwise be ~30x slower than Release.
    static func encode(_ samples: [Int16], coefficients coefs: [Int16]) -> (Data, [Int16]) {
        let frameCount = (samples.count + 13) / 14
        var out = [UInt8](repeating: 0, count: frameCount * 8)
        var decoded = [Int16](repeating: 0, count: samples.count)
        let c32 = UnsafeMutablePointer<Int32>.allocate(capacity: 16)
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: 56) // nibbles, recon, best nibbles, best recon
        defer { c32.deallocate(); scratch.deallocate() }
        for k in 0..<16 { c32[k] = k < coefs.count ? Int32(coefs[k]) : 0 }
        let nibbles = scratch, recon = scratch + 14, bestNibbles = scratch + 28, bestRecon = scratch + 42
        var h1: Int32 = 0, h2: Int32 = 0
        samples.withUnsafeBufferPointer { xb in
        out.withUnsafeMutableBufferPointer { ob in
        decoded.withUnsafeMutableBufferPointer { db in
            let x = xb.baseAddress!, o = ob.baseAddress!, d = db.baseAddress!
            for f in 0..<frameCount {
                let start = f * 14
                let count = samples.count - start < 14 ? samples.count - start : 14
                var bestErr = Int64.max, bestHeader: UInt8 = 0
                for c in 0..<8 {
                    let c1 = c32[c * 2], c2 = c32[c * 2 + 1]
                    // Open-loop residual peak picks the scale to start from.
                    var peak: Int32 = 0
                    var p1 = h1, p2 = h2
                    for i in 0..<count {
                        let v = Int32(x[start + i])
                        var r = v - ((c1 * p1 + c2 * p2 + 1024) >> 11)
                        if r < 0 { r = -r }
                        if r > peak { peak = r }
                        p2 = p1; p1 = v
                    }
                    var e0 = 0
                    while e0 < 12, (7 << e0) < peak { e0 += 1 }
                    let eLo = e0 > 0 ? e0 - 1 : 0, eHi = e0 < 12 ? e0 + 1 : 12
                    for e in eLo...eHi {
                        let scale = Int32(1) << e, half = scale >> 1
                        var err: Int64 = 0
                        var q1 = h1, q2 = h2
                        for i in 0..<count {
                            let base = (c1 * q1 + c2 * q2 + 1024) >> 11
                            let v = Int32(x[start + i])
                            let diff = v - base
                            var n = diff >= 0 ? (diff + half) >> e : -((half - diff) >> e)
                            if n > 7 { n = 7 } else if n < -8 { n = -8 }
                            var s = n * scale + base
                            if s > 32767 { s = 32767 } else if s < -32768 { s = -32768 }
                            nibbles[i] = n; recon[i] = s
                            let dv = Int64(v - s)
                            err += dv * dv
                            if err >= bestErr { break }
                            q2 = q1; q1 = s
                        }
                        if err < bestErr {
                            bestErr = err
                            bestHeader = UInt8(c << 4 | e)
                            bestNibbles.update(from: nibbles, count: count)
                            bestRecon.update(from: recon, count: count)
                        }
                    }
                }
                o[f * 8] = bestHeader
                for i in 0..<count {
                    let nib = UInt8(truncatingIfNeeded: bestNibbles[i]) & 0x0F
                    o[f * 8 + 1 + i / 2] |= i % 2 == 0 ? nib << 4 : nib
                    d[start + i] = Int16(truncatingIfNeeded: bestRecon[i])
                }
                h1 = bestRecon[count - 1]
                h2 = count >= 2 ? bestRecon[count - 2] : h1
            }
        }
        }
        }
        return (Data(out), decoded)
    }
}
