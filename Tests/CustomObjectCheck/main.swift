// Self-check for custom objects: a model built for a host must come out as a .brres whose MDL0 is
// named after the host's resource, or the game never finds it.
//
//   swiftc -O -o /tmp/customobjcheck -parse-as-library \
//     "Revolution IDE/Core/BinaryIO.swift" \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRRES,BRRESIndexGroup,BRRESTypes,TextureCodec,MathTypes,OBJImporter,MDL0Writer,MapModelBuilder,OBJToBRRES,ImageUtil,MDL0,MKDD/RARC}.swift \
//     Tests/CustomObjectCheck/main.swift
//   /tmp/customobjcheck

import Foundation

@main enum CustomObjectCheck {
    static func main() throws {
        let cube = """
        v 0 0 0\nv 100 0 0\nv 100 100 0\nv 0 100 0\nv 0 0 100\nv 100 0 100\nv 100 100 100\nv 0 100 100
        f 1 2 3\nf 1 3 4\nf 5 6 7\nf 5 7 8\nf 1 2 6\nf 1 6 5\nf 4 3 7\nf 4 7 8
        """
        let dir = FileManager.default.temporaryDirectory
        let objURL = dir.appendingPathComponent("cube.obj")
        try cube.write(to: objURL, atomically: true, encoding: .utf8)
        var failures = 0
        for host in ["gardentreeDS", "DKtreeA64", "TownTreeDS"] {
            guard let r = OBJToBRRES.convert(objText: cube, objURL: objURL, modelName: host) else { print("FAIL convert \(host)"); failures += 1; continue }
            let doc = BRRESDocument()
            doc.resources.append(contentsOf: r.textures); doc.resources.append(r.model)
            let data = doc.serialize()
            let back = try BRRESDocument.parse(data)
            let ok = back.resources.contains { $0.name == host && $0.folderName == "3DModels(NW4R)" } && r.triangleCount == 8
            print(ok ? "ok   \(host)" : "FAIL \(host)"); if !ok { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
