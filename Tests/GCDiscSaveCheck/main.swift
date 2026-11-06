import Foundation
@main struct Main { static func main() throws {
    let src = URL(fileURLWithPath: "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso")
    let tmp = URL(fileURLWithPath: CommandLine.arguments[1])
    try? FileManager.default.removeItem(at: tmp)
    try FileManager.default.copyItem(at: src, to: tmp) // APFS clone
    func find(_ n: DiscNode, _ name: String) -> DiscNode? { n.name == name ? n : n.children.lazy.compactMap { find($0, name) }.first }
    var disc = try openDiscImage(tmp, commonKey: nil, koreanKey: nil)
    precondition(disc is GameCubeDisc)
    let small = find(disc.root, "Luigi.arc")!, other = find(disc.root, "Mario.arc")!
    let otherBefore = try disc.readFile(node: other)
    let bigger = Data(repeating: 0xAB, count: Int(small.fileSize) * 2 + 123)
    try FileOperations.writeDiscEntry(discURL: tmp, disc: disc, node: small, data: bigger) { print($0) }
    let shorter = Data(repeating: 0xCD, count: 1000)
    try FileOperations.writeDiscEntry(discURL: tmp, disc: disc, node: other, data: shorter) { print($0) }
    disc = try openDiscImage(tmp, commonKey: nil, koreanKey: nil)
    let g = try disc.readFile(node: find(disc.root, "Luigi.arc")!); precondition(g == bigger, "grown file")
    let sh = try disc.readFile(node: find(disc.root, "Mario.arc")!); precondition(sh == shorter, "shrunk file")
    // Every other file unchanged vs the original disc.
    let orig = try openDiscImage(src, commonKey: nil, koreanKey: nil)
    var checked = 0
    func walk(_ a: DiscNode) throws {
        if a.children.isEmpty, a.name != "Luigi.arc", a.name != "Mario.arc", let b = find(disc.root, a.name), b.fileSize == a.fileSize, a.fileSize < 4_000_000 {
            let x = try orig.readFile(node: a), y = try disc.readFile(node: b); precondition(x == y, a.name); checked += 1
        }
        for c in a.children { try walk(c) }
    }
    try walk(orig.root)
    print("OK, \(checked) other files intact; before \(otherBefore.count) bytes")
    try FileManager.default.removeItem(at: tmp)
}}
