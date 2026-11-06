// Self-check for New > Skybox > Custom: a panorama image must come out as a .brres holding an MDL0
// named "vrcorn" (what the game looks up), textured, and sized like retail sky domes.
//
//   swiftc -O -o /tmp/skyboxcheck -parse-as-library \
//     "Revolution IDE/Core/BinaryIO.swift" \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRRES,BRRESIndexGroup,BRRESTypes,TextureCodec,MathTypes,OBJImporter,MDL0Writer,MapModelBuilder,OBJToBRRES,ImageUtil,MDL0,MKDD/RARC,Skybox}.swift \
//     Tests/SkyboxCheck/main.swift
//   /tmp/skyboxcheck

import AppKit

@main enum SkyboxCheck {
    static func main() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let px = rep.bitmapData!
        for y in 0..<256 { for x in 0..<512 {
            let o = y * rep.bytesPerRow + x * 4
            px[o] = UInt8(x / 2); px[o + 1] = 128; px[o + 2] = UInt8(y); px[o + 3] = 255
        } }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("pano.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)

        let data = try Skybox.brres(from: png)
        let doc = try BRRESDocument.parse(data)
        var failures = 0
        func check(_ c: Bool, _ m: String) { print(c ? "ok   \(m)" : "FAIL \(m)"); if !c { failures += 1 } }
        let mdl = doc.resources.first { $0.magic == "MDL0" }
        check(mdl?.name == "vrcorn", "MDL0 named vrcorn")
        check(doc.resources.contains { $0.magic == "TEX0" }, "has a texture")
        if let mdl, let m = MDL0Parser.parse(mdl, rawFile: data) {
            check(abs(m.boundsMax.y - Skybox.radius) < 100 && abs(m.boundsMin.y + Skybox.radius) < 100, "dome spans +/- radius (\(m.boundsMin.y)...\(m.boundsMax.y))")
            check(!m.meshes.isEmpty, "has a mesh")
        } else { check(false, "MDL0 parses") }
        exit(failures == 0 ? 0 : 1)
    }
}
