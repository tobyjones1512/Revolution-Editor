// KCL flag guessing from material/texture names: base type and documented variant.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -parse-as-library -o /tmp/flagcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/KCLFlagGuessCheck/main.swift && /tmp/flagcheck

import Foundation

@main enum KCLFlagGuessCheck {
    static func main() {
        var failures = 0
        func expect(_ name: String, _ want: UInt16, texture: String? = nil) {
            let got = OBJImporter.guessFlag(materialName: name, textureName: texture)
            let ok = got == want
            if !ok { failures += 1 }
            print(ok ? "ok  " : "FAIL", "\"\(name)\"\(texture.map { " (texture \($0))" } ?? "") -> \(kclFlagName(got))\(ok ? "" : ", wanted \(kclFlagName(want))")")
        }
        expect("road", 0x0000)                                  // Road - Normal Road
        expect("grass weak off road", 0x0002 | 3 << 5)          // Weak Off-road - Grass, Darker GFX
        expect("GrassWeakOffroad", 0x0002 | 3 << 5)             // camelCase
        expect("grass", 0x0003 | 4 << 5)                        // Off-road - Grass
        expect("heavy_offroad_snow", 0x0004 | 5 << 5)           // Heavy Off-road - Snow
        expect("wood road", 0x0000 | 4 << 5)                    // Road - Wood
        expect("metal_grate", 0x0000 | 6 << 5)                  // Road - Metal Grate
        expect("dirt", 0x0002 | 1 << 5)                         // Weak Off-road - Dirt
        expect("sand", 0x0002)                                  // Weak Off-road - Orange Sand
        expect("boost", 0x0006)
        expect("dash panel", 0x0006)
        expect("trick ramp", 0x0007)
        expect("jump pad", 0x0008)
        expect("lava", 0x0010 | 2 << 5)                         // Fall Boundary - Lava
        expect("water", 0x0010 | 1 << 5)                        // Fall Boundary - Water
        expect("wall", 0x000C)
        expect("rock wall", 0x000C | 1 << 5)                    // Wall - Rock
        expect("invisible wall", 0x000D)
        expect("ice", 0x0005)
        expect("Material.001", 0x0000, texture: "textures/Road_Asphalt.png") // falls through to the texture name
        expect("Material.001", 0x0002 | 3 << 5, texture: "grass_weak_offroad.png")
        expect("kcl_0x83", 0x0083)                              // explicit flag
        expect("Material.001", 0x0000)                          // nothing recognisable: road
        if failures > 0 { exit(1) }
    }
}
