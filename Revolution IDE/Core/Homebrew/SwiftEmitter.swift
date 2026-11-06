import Foundation

/// Entry point for translating a parsed Swift program to C.
nonisolated enum SwiftEmitter {
    typealias Output = SwiftTranslator.Output

    static let hookNames = SwiftTranslator.hookNames

    static func emit(_ prog: SwiftProgram, widgets: [String], sprites: [String] = [], sounds: [String] = [], musics: [String] = [], testing: Bool = false) throws -> Output {
        var program = prog
        if prog.types.contains(where: { $0.conformances.contains("View") || $0.conformances.contains("App") }) {
            try SwiftParser.parse(source: SwiftPrelude.swiftUI, file: "SwiftUI", into: &program)
        }
        return try SwiftTranslator(prog: program, widgets: widgets, sprites: sprites, sounds: sounds, musics: musics, testing: testing).run()
    }
}
