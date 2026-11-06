// Designer + node editor code generation check. Writes the generated C for the sample UI and
// node graph into <outdir>; run.sh then compiles it against host stubs of libogc, simulates a
// pointer click on the button, and checks the rendered frame and the node logic.
//
//   Tests/HomebrewUICheck/run.sh

import Foundation

@main enum HomebrewUICheck {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/hbui")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

        let ui = UIDocument.sample()
        check(ui.problems().isEmpty, "sample UI has no problems")
        let rt = try UIDocument.parse(ui.serialize())
        check(rt == ui, "UI document round-trips through JSON")
        let gen = UICodegen.generate(ui, projectRoot: out)
        check(gen.warnings.isEmpty, "UI codegen: no warnings")
        try gen.header.write(to: out.appendingPathComponent("ui_generated.h"), atomically: true, encoding: .utf8)
        try gen.source.write(to: out.appendingPathComponent("ui_generated.c"), atomically: true, encoding: .utf8)
        try WiiUIRuntime.header.write(to: out.appendingPathComponent("wiiui.h"), atomically: true, encoding: .utf8)
        try WiiUIRuntime.nodeHeader.write(to: out.appendingPathComponent("wn.h"), atomically: true, encoding: .utf8)
        try WiiUIRuntime.gfxHeader.write(to: out.appendingPathComponent("wgfx.h"), atomically: true, encoding: .utf8)
        try WiiUIRuntime.gfxSourceGX.write(to: out.appendingPathComponent("wgfx_gx.c"), atomically: true, encoding: .utf8)
        try WiiUIRuntime.source.write(to: out.appendingPathComponent("wiiui.c"), atomically: true, encoding: .utf8)

        let graph = NodeGraph.sample()
        check(try NodeGraph.parse(graph.serialize()) == graph, "graph round-trips through JSON")
        let logic = try NodeCodegen.generate(graph, widgetNames: ui.widgets.map(\.name))
        try logic.write(to: out.appendingPathComponent("logic_generated.c"), atomically: true, encoding: .utf8)
        check(logic.contains("case UI_GO:") && logic.contains("v_count"), "logic has the button handler and variable")

        // Errors: a button handler for a widget that isn't in the UI, and an exec loop.
        var bad = graph
        bad.nodes[0].params["widget"] = "nope"
        do { _ = try NodeCodegen.generate(bad, widgetNames: ["go"]); check(false, "unknown widget is rejected") }
        catch { check(true, "unknown widget is rejected") }
        var loop = NodeGraph()
        let ev = GraphNode.make(.onStart, x: 0, y: 0), br = GraphNode.make(.branch, x: 0, y: 0)
        loop.nodes = [ev, br]
        _ = loop.connect(GraphEdge(fromNode: ev.id, fromPort: "then", toNode: br.id, toPort: "in"))
        _ = loop.connect(GraphEdge(fromNode: br.id, fromPort: "true", toNode: br.id, toPort: "in"))
        check(loop.edges.count == 1, "a node can't be wired to itself")
        check(!loop.connect(GraphEdge(fromNode: ev.id, fromPort: "then", toNode: br.id, toPort: "condition")), "exec can't feed a data input")

        // The node-based game: assets, generated sprites/sounds, logic.
        let game = out.appendingPathComponent("game")
        try? FileManager.default.removeItem(at: game)
        try HomebrewSamples.writeAssets(into: game)
        let screen = UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: [])
        let gameGen = UICodegen.generate(screen, projectRoot: game)
        check(gameGen.warnings.isEmpty, "game assets: no warnings (\(gameGen.warnings))")
        check(gameGen.spriteNames == ["ball"] && gameGen.soundNames == ["blip"], "game assets: sprite 'ball' and sound 'blip' found")
        for (name, text) in [("ui_generated.h", gameGen.header), ("ui_generated.c", gameGen.source)] { try text.write(to: game.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let gameLogic = try NodeCodegen.generate(HomebrewSamples.gameGraph(), widgetNames: [], spriteNames: gameGen.spriteNames, soundNames: gameGen.soundNames)
        try gameLogic.write(to: game.appendingPathComponent("logic_generated.c"), atomically: true, encoding: .utf8)
        check(gameLogic.contains("void app_on_draw") && gameLogic.contains("wiiui_draw_rect") && gameLogic.contains("wiiui_held(0)"), "game graph: draw and input nodes generate code")
        var badSprite = HomebrewSamples.gameGraph()
        let evDraw = GraphNode.make(.onDraw, x: 0, y: 0), spr = GraphNode.make(.drawSprite, x: 0, y: 0)
        badSprite.nodes += [evDraw, spr]
        _ = badSprite.connect(GraphEdge(fromNode: evDraw.id, fromPort: "then", toNode: spr.id, toPort: "in"))
        do { _ = try NodeCodegen.generate(badSprite, widgetNames: [], spriteNames: ["ball"], soundNames: []); check(false, "a Draw Sprite with no sprite chosen is rejected") }
        catch { check(true, "a Draw Sprite with no sprite chosen is rejected") }

        // Texture data: decode what was generated with the app's own (retail-verified) decoder.
        let ball = UICodegen.loadImage(game.appendingPathComponent("assets/ball.png"))
        check(ball?.w == 32 && ball?.h == 32, "ball.png loads at 32x32")

        print(failures == 0 ? "GENERATED OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
