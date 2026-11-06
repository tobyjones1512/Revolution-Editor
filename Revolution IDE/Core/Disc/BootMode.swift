import Foundation

/// Right-click "WII DISC" > toggle boot mode. Byte 0 of the disc is normally 'R' (0x52); setting
/// it to 0x00 makes the disc auto-boot instead of going through the system menu channel (FAQ Q21).
nonisolated enum BootMode {
    static func toggle(discURL: URL, currentByte: UInt8) throws -> UInt8 {
        let newByte: UInt8 = currentByte == 0 ? 0x52 : 0x00
        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }
        try writer.write(Data([newByte]), at: 0)
        return newByte
    }
}
