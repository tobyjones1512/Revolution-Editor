import Foundation

enum Dir { case up, down, left, right }

struct Vec {
    var x: Int = 0
    var y: Int = 0

    mutating func move(_ d: Dir, by n: Int) {
        switch d {
        case .up: y -= n
        case .down: y += n
        case .left: x -= n
        case .right: x += n
        }
    }

    func manhattan() -> Int {
        return abs(x) + abs(y)
    }
}

let size = 4
var grid = [Int](repeating: 0, count: size * 2)
var pos = Vec()
var count = 0
var name = "Wii"
var ratio: Double = 1.5
var lives: Int = 3

func fib(_ n: Int) -> Int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}

func average(_ a: Int, _ b: Int) -> Double {
    return Double(a + b) / 2
}

func classify(_ n: Int) -> String {
    switch n {
    case 0: return "zero"
    case 1...9: return "small"
    default: return "big"
    }
}

func clamp(_ v: Int, low: Int, high: Int) -> Int {
    return min(max(v, low), high)
}

func appOnStart() {
    setText(UI.title, "Hello \(name)")
}

func appOnButton(_ id: Int) {
    if id == UI.go {
        count += 1
        pos.move(.right, by: 3)
        pos.move(.down, by: 2)
        for i in 0..<size { grid[i] = i * i }
        var sum = 0
        for v in grid { sum += v }
        var steps = 0
        while steps < 3 { steps += 1 }
        let label = classify(sum)
        let ok = count > 0 && lives == 3
        setText(UI.status, "n=\(count) fib=\(fib(10)) d=\(pos.manhattan()) sum=\(sum) \(label) avg=\(average(3, 4)) c=\(clamp(99, low: 0, high: 10)) \(ok ? "yes" : "no") \(steps)")
    }
}

func appOnWpad(_ pressed: UInt32) {
    if pressed & Button.b != 0 {
        ratio = ratio * 2
        setText(UI.title, "ratio \(ratio)")
    }
}
