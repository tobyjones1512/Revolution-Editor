import Foundation
import CommonCrypto
import CryptoKit

/// AES-128-CBC and SHA-1 primitives, plus the "Trucha bug" fake-signing routine that the real
/// Wii scrubbing/patching tools rely on to make modified tickets/TMDs pass IOS's (buggy)
/// signature check without needing Nintendo's private signing key.
nonisolated enum WiiCrypto {

    // MARK: AES-128-CBC

    static func aesCBC(operation: Int, key: [UInt8], iv: [UInt8], data: Data) -> Data {
        precondition(key.count == kCCKeySizeAES128)
        let ivBytes = iv
        let keyBytes = key
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLength = 0

        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            data.withUnsafeBytes { inPtr -> CCCryptorStatus in
                keyBytes.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                    ivBytes.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                        CCCrypt(CCOperation(operation),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0), // no padding, raw CBC
                                keyPtr.baseAddress, keyPtr.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, inPtr.count,
                                outPtr.baseAddress, outPtr.count,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return Data() }
        return out.prefix(outLength)
    }

    static func aesDecrypt(key: [UInt8], iv: [UInt8], data: Data) -> Data {
        aesCBC(operation: kCCDecrypt, key: key, iv: iv, data: data)
    }

    static func aesEncrypt(key: [UInt8], iv: [UInt8], data: Data) -> Data {
        aesCBC(operation: kCCEncrypt, key: key, iv: iv, data: data)
    }

    // MARK: SHA-1

    static func sha1(_ data: Data) -> Data {
        var digest = Insecure.SHA1()
        digest.update(data: data)
        return Data(digest.finalize())
    }

    // MARK: Trucha bug fake-signing

    /// Real Wii IOS versions before the "Trucha bug" fix never actually verified the RSA
    /// signature bytes on a ticket/TMD, they only checked whether the SHA-1 hash of the signed
    /// body happened to start with a 0x00 byte. Homebrew signing tools of that era
    /// exploited this by brute-forcing a spare padding field inside the signed
    /// region until that condition held, then left the actual signature bytes as garbage/zero.
    ///
    /// This does nothing to real, unmodified discs (their signatures are already valid); it only
    /// matters once we've modified a ticket/TMD's signed contents (e.g. after replacing
    /// a file, shrinking a partition, or 0-filling padding under TRUCHA mode) and needs the result
    /// to still boot on real/patched IOS.
    ///
    /// - Parameters:
    ///   - data: the full ticket or TMD buffer, modified in place.
    ///   - signedRange: the range of bytes that are actually SHA-1 hashed for the signature check.
    ///   - paddingOffset: a 2-byte field inside `signedRange` that is otherwise unused/reserved and
    ///     safe to overwrite with an arbitrary counter value.
    /// - Returns: true if a fake-signed padding value was found (should always succeed; expected
    ///   ~256 tries on average, capped generously below).
    @discardableResult
    static func truchaSign(_ data: inout Data, signedRange: Range<Int>, paddingOffset: Int) -> Bool {
        // Zero the actual signature so it's obviously not a real Nintendo signature.
        // (sig type at +0..<4, signature at +4..<260 for standard RSA-2048 sigs)
        if data.count >= 260 {
            for i in 4..<260 { data[data.startIndex + i] = 0 }
        }

        var counter: UInt16 = 0
        let base = data.startIndex
        repeat {
            data[base + paddingOffset] = UInt8((counter >> 8) & 0xFF)
            data[base + paddingOffset + 1] = UInt8(counter & 0xFF)
            let signed = data.subdata(in: (base + signedRange.lowerBound)..<(base + signedRange.upperBound))
            let hash = sha1(signed)
            if hash.first == 0x00 { return true }
            counter = counter &+ 1
        } while counter != 0
        return false
    }
}
