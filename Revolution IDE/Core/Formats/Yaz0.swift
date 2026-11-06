import Foundation

/// Nintendo's "Yaz0" LZSS-family compression, used to wrap .szs/.arc archives (and many other
/// GC/Wii assets). Format: 4-byte magic ("Yaz0" or the byte-swapped "Yaz1"), a big-endian u32
/// decompressed size, 8 reserved/padding bytes, then the compressed stream itself: repeating
/// "chunks" of one flag byte (8 bits, MSB first) followed by up to 8 tokens --
///   flag bit 1: copy the next literal byte straight to the output.
///   flag bit 0: a back-reference, encoded in 2 or 3 bytes:
///     byte0 high nibble = (length - 2), unless it's 0 (meaning a 3rd length byte follows,
///       holding length - 18); byte0 low nibble + byte1 = (distance - 1), 12 bits total.
nonisolated enum Yaz0 {
    private static let magicYaz0: [UInt8] = Array("Yaz0".utf8)

    static func isYaz0(_ data: Data) -> Bool {
        data.count >= 4 && [UInt8](data.prefix(4)) == magicYaz0
    }

    static func decode(_ data: Data) throws -> Data {
        guard data.count >= 16, [UInt8](data.prefix(4)) == magicYaz0 else {
            throw WSError.badStructure("Not a Yaz0-compressed file.")
        }
        let decompressedSize = Int(data.be32(4))
        // Sanity cap: a corrupt/malicious header claiming a huge decompressed size would otherwise
        // trigger a huge up-front allocation before a single byte of the (possibly tiny) compressed
        // stream has even been validated, crashing or hanging the app just from opening the file.
        // 512MB is comfortably above any real Yaz0-compressed asset this app works with (course
        // archives are a few MB; the largest real files found on a real MKWii disc are ~2MB).
        guard decompressedSize >= 0, decompressedSize <= 512 * 1024 * 1024 else {
            throw WSError.badStructure("Yaz0 decompressed size (\(decompressedSize) bytes) looks implausible for a real file.")
        }
        var out = [UInt8](repeating: 0, count: decompressedSize)
        let src = [UInt8](data)
        var srcPos = 16
        var dstPos = 0
        var flagByte: UInt8 = 0
        var flagBitsLeft = 0

        while dstPos < decompressedSize {
            if flagBitsLeft == 0 {
                guard srcPos < src.count else { throw WSError.badStructure("Yaz0 stream truncated.") }
                flagByte = src[srcPos]; srcPos += 1
                flagBitsLeft = 8
            }
            let literal = (flagByte & 0x80) != 0
            flagByte <<= 1
            flagBitsLeft -= 1

            if literal {
                guard srcPos < src.count, dstPos < decompressedSize else { throw WSError.badStructure("Yaz0 stream truncated.") }
                out[dstPos] = src[srcPos]; srcPos += 1; dstPos += 1
            } else {
                guard srcPos + 1 < src.count else { throw WSError.badStructure("Yaz0 stream truncated.") }
                let b0 = src[srcPos], b1 = src[srcPos + 1]; srcPos += 2
                let distance = Int(b0 & 0x0F) << 8 | Int(b1)
                var length = Int(b0 >> 4)
                if length == 0 {
                    guard srcPos < src.count else { throw WSError.badStructure("Yaz0 stream truncated.") }
                    length = Int(src[srcPos]) + 0x12; srcPos += 1
                } else {
                    length += 2
                }
                let copySource = dstPos - (distance + 1)
                guard copySource >= 0 else { throw WSError.badStructure("Yaz0 back-reference out of range.") }
                for i in 0..<length {
                    guard dstPos < decompressedSize else { break }
                    out[dstPos] = out[copySource + i]
                    dstPos += 1
                }
            }
        }
        return Data(out)
    }

    /// Nintendo's own Yaz0 compressor, reproduced so the streams this app writes are the ones the
    /// game's own tools would have written.
    ///
    /// The algorithm is not "find the longest match": it is an exhaustive scan of the 4096-byte
    /// window that keeps the *earliest* longest match, plus a one-byte lookahead that gives up a
    /// match in favour of a literal when the next position can do at least two bytes better.
    /// Both details are load-bearing for byte-exactness, `beginner_course.szs` off a retail disc
    /// re-compresses to itself byte for byte with them and does not without.
    ///
    /// Reproduced from the compressor in Nintendo's SDK (the `simpleEnc`/`nintendoEnc` pair that
    /// every Yaz0 tool descends from) and verified against that real file, not inferred from the
    /// format description. The previous encoder here searched a truncated hash chain and kept the
    /// most recent match, which is valid Yaz0, it decodes correctly, but produced a stream
    /// ~1% larger and sharing almost no bytes with Nintendo's.
    static func encode(_ input: Data, alignment: UInt32 = 0) -> Data {
        let src = [UInt8](input)
        let n = src.count
        let w = MutableDataWriter()
        w.putData(Data(magicYaz0))
        w.putU32(UInt32(n))
        w.putU32(alignment)
        w.putU32(0)

        let windowSize = 0x1000
        let maxMatch = 0x111 // 3-byte length field: 0xFF + 0x12

        // A chain over 3-byte sequences, holding *every* position so the walk below sees exactly
        // the candidates a linear scan of the window would, only faster.
        var head = [Int](repeating: -1, count: 1 << 16)
        var chain = [Int](repeating: -1, count: max(n, 1))
        @inline(__always) func key(_ i: Int) -> Int {
            (Int(src[i]) << 8 | Int(src[i + 1])) ^ (Int(src[i + 2]) &* 0x9E37)
        }
        @inline(__always) func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = key(i) & 0xFFFF
            chain[i] = head[h]
            head[h] = i
        }
        // Nintendo's search rescans the raw window, so every position before the one being
        // examined is always a candidate. A chain filled only as tokens are emitted lags behind
        // that: the one-byte lookahead examines `pos + 1` while `pos` itself has not been added
        // yet, so it could not see the run starting one byte later and the lookahead never fired.
        // Positions are therefore inserted as soon as the search moves past them, not on emit.
        var insertedUpTo = 0
        @inline(__always) func fillChain(before limit: Int) {
            while insertedUpTo < limit { insert(insertedUpTo); insertedUpTo += 1 }
        }

        /// `simpleEnc`: the longest match for `pos` in the preceding 4096 bytes, preferring the
        /// earliest candidate on a tie, and reported as a literal (length 1) when it would only
        /// be two bytes long. The chain runs newest-to-oldest, so `>=` is what keeps the earliest.
        @inline(__always) func longestMatch(at pos: Int) -> (length: Int, position: Int) {
            guard pos + 2 < n else { return (1, 0) }
            fillChain(before: pos)
            let startPos = max(0, pos - windowSize)
            // Clamped to the longest encodable run. Two candidates that both run past 0x111 are
            // therefore a tie, and the earliest wins, which is exactly what retail does: at
            // output offset 542919 of `beginner_course.szs` two matches both reach 0x111 and
            // Nintendo takes the one 1600 bytes back, not the nearer one at 1496.
            let maxLen = min(maxMatch, n - pos)
            var bestLength = 1
            var bestPosition = 0
            var candidate = head[key(pos) & 0xFFFF]
            while candidate >= startPos {
                // A candidate can only tie or beat the best if it at least reaches its last byte.
                // Skipping on that one comparison is what keeps an exhaustive window scan cheap.
                if src[candidate + bestLength - 1] == src[pos + bestLength - 1] {
                    var length = 0
                    while length < maxLen, src[candidate + length] == src[pos + length] { length += 1 }
                    // `>=`, walking newest to oldest, leaves the *earliest* longest match, which
                    // is what a forward scan keeping strictly-longer matches arrives at.
                    if length >= bestLength { bestLength = length; bestPosition = candidate }
                }
                candidate = chain[candidate]
            }
            return bestLength == 2 ? (1, 0) : (bestLength, bestPosition)
        }

        var out = [UInt8]()
        out.reserveCapacity(n / 2)
        var chunk = [UInt8]()
        chunk.reserveCapacity(24)
        var flag: UInt8 = 0
        var bitsUsed = 0
        var pos = 0

        // `nintendoEnc`'s carried state: when the lookahead wins, the match it found is used on
        // the following iteration rather than searched for again.
        var haveDeferred = false
        var deferredLength = 0
        var deferredPosition = 0

        while pos < n {
            var length: Int
            var matchPosition: Int
            if haveDeferred {
                length = deferredLength
                matchPosition = deferredPosition
                haveDeferred = false
            } else {
                (length, matchPosition) = longestMatch(at: pos)
                if length >= 3, pos + 1 < n {
                    let next = longestMatch(at: pos + 1)
                    // Only a clear win, two bytes better, justifies spending a literal here.
                    if next.length >= length + 2 {
                        length = 1
                        haveDeferred = true
                        deferredLength = next.length
                        deferredPosition = next.position
                    }
                }
            }

            if length >= 3 {
                let distance = pos - matchPosition - 1
                if length < 0x12 {
                    chunk.append(UInt8(((length - 2) << 4) | ((distance >> 8) & 0x0F)))
                    chunk.append(UInt8(distance & 0xFF))
                } else {
                    chunk.append(UInt8((distance >> 8) & 0x0F))
                    chunk.append(UInt8(distance & 0xFF))
                    chunk.append(UInt8(length - 0x12))
                }
            } else {
                length = 1
                flag |= (0x80 >> UInt8(bitsUsed))
                chunk.append(src[pos])
            }

            pos += length
            fillChain(before: pos)

            bitsUsed += 1
            if bitsUsed == 8 {
                out.append(flag)
                out.append(contentsOf: chunk)
                flag = 0
                bitsUsed = 0
                chunk.removeAll(keepingCapacity: true)
            }
        }
        // Unconditional, not `if bitsUsed > 0`: the reference encoder writes the trailing flag
        // byte whether or not the last group holds anything, so a token count that is an exact
        // multiple of 8 still ends with an empty 0x00 flag. `lb_bike-rs.szs` and `mc_bike-ys.szs`
        // have 132424 and 132920 tokens, both multiples of 8, and were the only thing
        // separating this encoder's output from theirs.
        out.append(flag)
        out.append(contentsOf: chunk)
        w.putData(Data(out))
        return w.data
    }
}
