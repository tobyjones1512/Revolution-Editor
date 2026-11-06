import AVFoundation
import UniformTypeIdentifiers
import Accelerate

/// Decodes any audio file AVFoundation can read into 16-bit channels at `sampleRate`.
nonisolated enum AudioFileImport {
    /// Audio files offered for conversion to BRSTM (anything else AVFoundation reads works too).
    static let convertibleExtensions: Set<String> = ["mp3", "wav", "wave", "aif", "aiff", "aifc", "m4a", "flac", "caf"]
    static var contentTypes: [UTType] {
        [.mp3, .wav, .aiff, .audio] + ["aifc", "flac", "caf"].compactMap { UTType(filenameExtension: $0) }
    }

    static func load(_ url: URL, sampleRate: Double) throws -> (channels: [[Int16]], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        guard src.channelCount >= 1, src.channelCount <= 8 else {
            throw WSError.badStructure("That file has \(src.channelCount) channels; a BRSTM can hold 1 to 8.")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw WSError.badStructure("Couldn't allocate a buffer for that audio.")
        }
        try file.read(into: input)
        var buffer = input
        if src.sampleRate != sampleRate {
            guard let dst = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: src.channelCount),
                  let converter = AVAudioConverter(from: src, to: dst),
                  let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * sampleRate / src.sampleRate) + 1024) else {
                throw WSError.badStructure("Couldn't resample that audio to \(Int(sampleRate)) Hz.")
            }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            buffer = out
        }
        guard let data = buffer.floatChannelData else { throw WSError.badStructure("Unsupported audio sample format.") }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { throw WSError.badStructure("That file has no audio.") }
        let n = vDSP_Length(frames)
        let channels = (0..<Int(buffer.format.channelCount)).map { ch -> [Int16] in
            var scaled = [Float](repeating: 0, count: frames)
            var k: Float = 32767, lo: Float = -32768, hi: Float = 32767
            vDSP_vsmul(data[ch], 1, &k, &scaled, 1, n)
            vDSP_vclip(scaled, 1, &lo, &hi, &scaled, 1, n)
            var out = [Int16](repeating: 0, count: frames)
            vDSP_vfixr16(scaled, 1, &out, 1, n)
            return out
        }
        return (channels, Int(sampleRate))
    }
}
