import Foundation
import AppKit

/// The starter games the Game templates write: the same bouncing-ball catch game in Swift, C and
/// nodes, plus the sprite and sound it uses (made here, so there's nothing to download).
nonisolated enum HomebrewSamples {
    static let gameSwift = """
    // A tiny game in Swift. appOnFrame updates the game, appOnDraw draws it.
    // The screen is 640 x 480 with y pointing down. Sprite.ball and Sound.blip are the files in assets/.

    struct Ball {
    	var x = 320
    	var y = 160
    	var dx = 4
    	var dy = 4
    }

    var ball = Ball()
    var paddleX = 270
    var score = 0
    var lives = 3

    func resetBall() {
    	ball = Ball()
    	if randomInt(0, 1) == 0 { ball.dx = -4 }
    }

    func appOnFrame() {
    	// D-pad, a stick, or point the Wii Remote at the screen.
    	if held(Button.left) { paddleX -= 8 }
    	if held(Button.right) { paddleX += 8 }
    	paddleX += Int(stickX() * 8)
    	if pointerVisible() { paddleX = pointerX() - 50 }
    	paddleX = max(0, min(540, paddleX))

    	ball.x += ball.dx
    	ball.y += ball.dy
    	if ball.x < 0 || ball.x > 608 {
    		ball.dx = -ball.dx
    		playSound(Sound.blip)
    	}
    	if ball.y < 0 {
    		ball.dy = -ball.dy
    		playSound(Sound.blip)
    	}
    	if ball.dy > 0 && overlaps(ball.x, ball.y, 32, 32, paddleX, 440, 100, 16) {
    		ball.dy = -ball.dy
    		score += 1
    		playSound(Sound.blip)
    	}
    	if ball.y > 480 {
    		lives -= 1
    		if lives == 0 {
    			score = 0
    			lives = 3
    		}
    		resetBall()
    	}
    }

    func appOnDraw() {
    	drawSprite(Sprite.ball, ball.x, ball.y)
    	drawRect(paddleX, 440, 100, 16, r: 80, g: 200, b: 120)
    	drawText("Score \\(score)   Lives \\(lives)", 20, 16, size: 24)
    }

    """

    /// A small SwiftUI app: a counter, a toggle and a list built with ForEach.
    static let swiftUI = """
    import SwiftUI

    // SwiftUI on the Wii. The body is drawn every frame, so @State changes show straight away.
    // Point at a button and press A, or use the D-pad to move the highlight and press A.

    struct Stat: View {
    	var label: String
    	var value: Int
    	var tint: Color

    	var body: some View {
    		VStack(spacing: 4) {
    			Text("\\(value)")
    				.font(.title)
    				.foregroundColor(.white)
    			Text(label)
    				.font(.caption)
    				.foregroundColor(.white.opacity(0.8))
    		}
    		.padding(12)
    		.frame(width: 130)
    		.background(tint)
    		.cornerRadius(14)
    	}
    }

    struct ContentView: View {
    	@State private var count = 0
    	@State private var soundOn = true
    	@State private var volume = 0.6
    	let todo = ["Install devkitPro", "Build the app", "Run it on a Wii"]

    	var body: some View {
    		VStack(spacing: 18) {
    			Text("Hello, SwiftUI!")
    				.font(.largeTitle)
    				.foregroundColor(.yellow)

    			HStack(spacing: 14) {
    				Stat(label: "Taps", value: count, tint: .blue)
    				Stat(label: "Double", value: count * 2, tint: .purple)
    			}

    			HStack(spacing: 12) {
    				Button("-1") { count -= 1 }
    				Button("+1") { count += 1 }
    				Button("Reset") { count = 0 }
    			}

    			Toggle("Sound", isOn: $soundOn)
    				.frame(width: 280)
    			Slider(value: $volume, in: 0...1)
    				.frame(width: 280)
    				.disabled(!soundOn)

    			VStack(alignment: .leading, spacing: 4) {
    				ForEach(todo, id: \\.self) { item in
    					Text("- " + item)
    				}
    			}
    		}
    	}
    }

    @main struct MyApp: App {
    	var body: some Scene {
    		WindowGroup { ContentView() }
    	}
    }

    """

    static let gameC = """
    #include <stdio.h>
    #include <stdlib.h>
    #include "generated/ui_generated.h"

    /* A tiny game in C. app_on_frame updates the game, app_on_draw draws it.
       The screen is 640 x 480 with y pointing down. SPRITE_BALL and SOUND_BLIP are the files in assets/. */

    static int ball_x = 320, ball_y = 160, ball_dx = 4, ball_dy = 4;
    static int paddle_x = 270, score = 0, lives = 3;

    static void reset_ball(void) {
    	ball_x = 320; ball_y = 160; ball_dx = rand() % 2 ? 4 : -4; ball_dy = 4;
    }

    void app_on_frame(void) {
    	/* D-pad, a stick, or point the Wii Remote at the screen. */
    	if (wiiui_held(0) & WPAD_BUTTON_LEFT) paddle_x -= 8;
    	if (wiiui_held(0) & WPAD_BUTTON_RIGHT) paddle_x += 8;
    	paddle_x += (int)(wiiui_stick_x(0) * 8);
    	int px, py;
    	if (wiiui_pointer(&px, &py)) paddle_x = px - 50;
    	if (paddle_x < 0) paddle_x = 0;
    	if (paddle_x > 540) paddle_x = 540;

    	ball_x += ball_dx;
    	ball_y += ball_dy;
    	if (ball_x < 0 || ball_x > 608) { ball_dx = -ball_dx; wiiui_play_sound(SOUND_BLIP); }
    	if (ball_y < 0) { ball_dy = -ball_dy; wiiui_play_sound(SOUND_BLIP); }
    	if (ball_dy > 0 && wiiui_rects_overlap(ball_x, ball_y, 32, 32, paddle_x, 440, 100, 16)) {
    		ball_dy = -ball_dy;
    		score++;
    		wiiui_play_sound(SOUND_BLIP);
    	}
    	if (ball_y > 480) {
    		if (--lives == 0) { score = 0; lives = 3; }
    		reset_ball();
    	}
    }

    void app_on_draw(void) {
    	char text[64];
    	wiiui_draw_sprite(SPRITE_BALL, ball_x, ball_y);
    	wiiui_draw_rect(paddle_x, 440, 100, 16, 80, 200, 120, 255);
    	snprintf(text, sizeof text, "Score %d   Lives %d", score, lives);
    	wiiui_draw_text(24, 20, 16, text, 255, 255, 255, 255);
    }

    int main(void) {
    	wiiui_init();
    	while (wiiui_frame()) {}
    	return 0;
    }

    """

    /// A square you move with the D-pad or a stick, drawn from nodes.
    static func gameGraph() -> NodeGraph {
        var g = NodeGraph()
        g.variables = [GraphVariable(name: "px", type: .number, initial: "300"), GraphVariable(name: "py", type: .number, initial: "220")]
        func node(_ k: NodeKind, _ x: Double, _ y: Double, _ p: [String: String] = [:]) -> GraphNode {
            var n = GraphNode.make(k, x: x, y: y)
            for (key, v) in p { n.params[key] = v }
            g.nodes.append(n)
            return n
        }
        func wire(_ a: GraphNode, _ ap: String, _ b: GraphNode, _ bp: String) { _ = g.connect(GraphEdge(fromNode: a.id, fromPort: ap, toNode: b.id, toPort: bp)) }

        // Every frame: four "if a direction is held, move" steps in a row, laid out two by two.
        let frame = node(.onFrame, 40, 40)
        var previous: (GraphNode, String) = (frame, "then")
        let moves: [(String, String, String, String)] = [("Left", "px", "subtract", "4"), ("Right", "px", "add", "4"), ("Up", "py", "add", "4"), ("Down", "py", "subtract", "4")]
        for (index, (button, variable, op, amount)) in moves.enumerated() {
            let gx = 260 + Double(index % 2) * 760, gy = 40 + Double(index / 2) * 270
            let branch = node(.branch, gx + 240, gy)
            let held = node(.buttonHeld, gx, gy + 60, ["button": button])
            let set = node(.setNumberVar, gx + 500, gy, ["variable": variable])
            let get = node(.getNumberVar, gx + 240, gy + 135, ["variable": variable])
            let math = node(op == "add" ? .add : .subtract, gx + 500, gy + 135, ["b": amount])
            wire(previous.0, previous.1, branch, "in")
            wire(held, "value", branch, "condition")
            wire(branch, "true", set, "in")
            wire(get, "value", math, "a")
            wire(math, "value", set, "value")
            previous = (branch, "regardless")
        }

        // Draw: the square at (px, py).
        let draw = node(.onDraw, 40, 620)
        let rect = node(.drawRect, 640, 560, ["size": "40, 40", "colour": "80, 200, 120"])
        let gx = node(.getNumberVar, 130, 700, ["variable": "px"]), gy = node(.getNumberVar, 130, 780, ["variable": "py"])
        let pos = node(.makeVector, 400, 700)
        wire(draw, "then", rect, "in")
        wire(gx, "value", pos, "x")
        wire(gy, "value", pos, "y")
        wire(pos, "vector", rect, "position")
        return g
    }

    // MARK: Sample assets

    /// `assets/ball.png` (a shaded ball) and `assets/blip.wav` (a short beep).
    static func writeAssets(into dir: URL) throws {
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try ballPNG().write(to: assets.appendingPathComponent("ball.png"))
        try blipWAV().write(to: assets.appendingPathComponent("blip.wav"))
    }

    static func ballPNG(size: Int = 32) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        guard let px = rep.bitmapData else { return Data() }
        let c = Double(size - 1) / 2
        for y in 0..<size { for x in 0..<size {
            let dx = Double(x) - c, dy = Double(y) - c
            let d = (dx * dx + dy * dy).squareRoot()
            let edge = max(0, min(1, c + 0.5 - d))                       // anti-aliased rim
            let lit = max(0, 1 - ((dx + 5) * (dx + 5) + (dy + 5) * (dy + 5)).squareRoot() / (c * 1.4))   // highlight, top left
            let o = (y * size + x) * 4
            px[o] = UInt8(255 * (0.9 + 0.1 * lit)); px[o + 1] = UInt8(255 * (0.45 + 0.5 * lit)); px[o + 2] = UInt8(255 * (0.2 + 0.6 * lit)); px[o + 3] = UInt8(255 * edge)
        } }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    static func blipWAV(rate: Int = 22050, seconds: Double = 0.12, hz: Double = 880) -> Data {
        let n = Int(Double(rate) * seconds)
        var pcm = Data()
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let v = Int16(sin(2 * .pi * hz * t) * 12000 * (1 - Double(i) / Double(n)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        var out = Data("RIFF".utf8)
        out.append(contentsOf: le32(36 + pcm.count))
        out.append(Data("WAVEfmt ".utf8))
        out.append(contentsOf: le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16))
        out.append(Data("data".utf8))
        out.append(contentsOf: le32(pcm.count))
        out.append(pcm)
        return out
    }
}
