// The Swift language features, tested by running them: each hostCheck is reported by the host.

struct Vec {
    var x: Int
    var y: Int
    static let zero = Vec(x: 0, y: 0)
    static var created = 0
    init(x: Int, y: Int) { self.x = x; self.y = y; Vec.created += 1 }
    var length2: Int { x * x + y * y }
    var scaled: Int { get { x * 10 } set { x = newValue / 10 } }
    mutating func add(_ o: Vec) { x += o.x; y += o.y }
    func plus(_ o: Vec) -> Vec { Vec(x: x + o.x, y: y + o.y) }
    static func make(_ n: Int) -> Vec { Vec(x: n, y: n) }
}

extension Vec {
    func flipped() -> Vec { Vec(x: y, y: x) }
}

final class Counter {
    var n = 0
    var log: [String] = []
    init(start: Int) { n = start }
    func bump(by d: Int = 1) -> Int { n += d; log.append("bump \(d)"); return n }
}

class Node {
    var value: Int
    var next: Node?
    init(_ v: Int) { value = v }
}

enum Dir: Int, CaseIterable { case up = 1, down, left, right
    func opposite() -> Dir {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
    var isVertical: Bool { self == .up || self == .down }
}

enum Level { case easy, hard }

typealias Pair = (Int, Int)

var total = 0
var names: [String] = ["b", "a", "c"]

func divmod(_ a: Int, _ b: Int) -> (quotient: Int, remainder: Int) { (a / b, a % b) }
func firstEven(_ xs: [Int]) -> Int? { xs.first(where: { $0 % 2 == 0 }) }
func addOne(_ x: inout Int) { x += 1 }
func describe(_ n: Int?) -> String { if let v = n { return "got \(v)" }; return "none" }
func sum(of xs: [Int]) -> Int { xs.reduce(0, +) }
func apply(_ f: (Int) -> Int, to x: Int) -> Int { f(x) }
func twice(_ f: () -> Void) { f(); f() }
func greet(_ name: String, punctuation: String = "!") -> String { "Hi " + name + punctuation }

func testBasics() {
    hostCheck(1 + 2 * 3 == 7, "arithmetic precedence")
    hostCheck(7 / 2 == 3 && 7 % 2 == 1, "integer division")
    hostCheck(Double(7) / 2 == 3.5, "double division")
    hostCheck("a" + "b" == "ab", "string +")
    hostCheck("\(1 + 1)x" == "2x", "interpolation")
    hostCheck(greet("Wii") == "Hi Wii!" && greet("Wii", punctuation: "?") == "Hi Wii?", "default arguments")
    let (q, r) = divmod(17, 5)
    hostCheck(q == 3 && r == 2, "tuple destructuring")
    let d = divmod(9, 4)
    hostCheck(d.quotient == 2 && d.remainder == 1 && d.0 == 2, "tuple labels and indexes")
    var a = 1, b = 2
    (a, b) = (b, a)
    hostCheck(a == 2 && b == 1, "tuple swap")
    swap(&a, &b)
    hostCheck(a == 1 && b == 2, "swap")
    var n = 5
    addOne(&n)
    hostCheck(n == 6, "inout")
    let p: Pair = (3, 4)
    hostCheck(p.0 + p.1 == 7, "typealias to a tuple")
    hostCheck(min(3, 9) == 3 && max(3, 9) == 9 && abs(-4) == 4, "min max abs")
    hostCheck("Wii".count == 3 && !"Wii".isEmpty && "".isEmpty, "string count")
    hostCheck("wii".uppercased() == "WII" && "ABC".lowercased() == "abc", "uppercased lowercased")
    hostCheck("hello".hasPrefix("he") && "hello".hasSuffix("lo") && "hello".contains("ell"), "string search")
    hostCheck(Int("42") == 42 && Int("x") == nil && Double("2.5") == 2.5, "parsing numbers")
    hostCheck(String(42) == "42" && String(true) == "true", "String()")
}

func testOptionals() {
    hostCheck(firstEven([1, 3, 4, 6]) == 4, "optional equals value")
    hostCheck(firstEven([1, 3]) == nil, "optional is nil")
    hostCheck(describe(5) == "got 5" && describe(nil) == "none", "if let")
    let x: Int? = nil
    let five: Int? = 5
    hostCheck((x ?? 9) == 9 && (five ?? 9) == 5, "nil coalescing")
    guard let v = firstEven([2]) else { hostCheck(false, "guard let"); return }
    hostCheck(v == 2, "guard let")
    var opt: Int? = 3
    opt = nil
    hostCheck(opt == nil, "assign nil")
    opt = 4
    hostCheck(opt! == 4, "force unwrap")
    let node = Node(1)
    node.next = Node(2)
    hostCheck(node.next?.value == 2 && node.next?.next?.value == nil, "optional chaining")
    if let a = Int("7"), let b = Int("8"), a < b { hostCheck(a + b == 15, "if let with several bindings") } else { hostCheck(false, "if let with several bindings") }
    var count = 0
    var cur: Node? = node
    while let c = cur { count += c.value; cur = c.next }
    hostCheck(count == 3, "while let")
}

func testArrays() {
    var xs = [1, 2, 3]
    xs.append(4)
    hostCheck(xs.count == 4 && xs[3] == 4, "append and subscript")
    xs[0] = 10
    xs += [5, 6]
    hostCheck(xs == xs && xs.count == 6 && xs[0] == 10 && xs[5] == 6, "assign element, +=")
    hostCheck(xs.remove(at: 0) == 10 && xs.removeLast() == 6 && xs.count == 4, "remove")
    xs.insert(9, at: 1)
    hostCheck(xs[1] == 9, "insert")
    hostCheck(xs.contains(9) && !xs.contains(100), "contains")
    hostCheck(xs.firstIndex(of: 9) == 1, "firstIndex(of:)")
    hostCheck(xs.first == 2 && xs.last == 5, "first last")
    let ys = [3, 1, 2]
    hostCheck(ys.sorted() == [1, 2, 3] && ys.sorted(by: { $0 > $1 }) == [3, 2, 1], "sorted")
    hostCheck(ys.map { $0 * 2 } == [6, 2, 4], "map")
    hostCheck(ys.filter { $0 > 1 } == [3, 2], "filter")
    hostCheck(ys.reduce(0) { $0 + $1 } == 6 && sum(of: ys) == 6, "reduce")
    hostCheck(ys.reversed() == [2, 1, 3], "reversed")
    hostCheck(ys.min() == 1 && ys.max() == 3, "min max")
    hostCheck(ys.allSatisfy { $0 > 0 } && ys.contains(where: { $0 == 2 }), "allSatisfy contains(where:)")
    var seen = 0
    ys.forEach { seen += $0 }
    hostCheck(seen == 6, "forEach changing a local")
    var zs: [Int] = []
    for i in 0..<5 { zs.append(i * i) }
    hostCheck(zs == [0, 1, 4, 9, 16], "building an array in a loop")
    var acc = 0
    for (i, v) in zs.enumerated() { acc += i * v }
    hostCheck(acc == 0 + 1 + 8 + 27 + 64, "enumerated")
    for v in zs.reversed() { acc -= v }
    hostCheck(acc == 100 - 30, "for over reversed()")
    hostCheck(names.sorted() == ["a", "b", "c"] && names.joined(separator: ",") == "b,a,c", "string arrays")
    let grid = [[1, 2], [3, 4]]
    hostCheck(grid[1][0] == 3 && grid.count == 2, "array of arrays")
    let reps = [Int](repeating: 7, count: 3)
    hostCheck(reps == [7, 7, 7] && reps.count == 3, "repeating")
    var ws = ["x"]
    ws.append(contentsOf: ["y", "z"])
    hostCheck(ws.count == 3 && ws.map { $0 + "!" } == ["x!", "y!", "z!"], "append(contentsOf:) and map on strings")
    let strs = [1, 2].map { "n\($0)" }
    hostCheck(strs[1] == "n2", "map to another type")
    hostCheck(zs.prefix(2) == [0, 1] && zs.dropFirst() == [1, 4, 9, 16], "prefix dropFirst")
    for i in stride(from: 0, to: 10, by: 3) { total += i }
    hostCheck(total == 0 + 3 + 6 + 9, "stride")
}

func testTypes() {
    var v = Vec(x: 1, y: 2)
    v.add(Vec(x: 2, y: 3))
    hostCheck(v.x == 3 && v.y == 5, "struct mutating method")
    hostCheck(v.length2 == 34, "computed property")
    v.scaled = 70
    hostCheck(v.x == 7 && v.scaled == 70, "computed setter")
    hostCheck(v.plus(.zero).x == 7 && Vec.make(2).y == 2, "static members and implicit .zero")
    hostCheck(v.flipped().x == v.y, "extension method")
    hostCheck(Vec.created >= 3, "static var")
    let copy = v
    v.x = 100
    hostCheck(copy.x == 7, "struct value semantics")

    let c = Counter(start: 10)
    let alias = c
    _ = alias.bump()
    hostCheck(c.n == 11 && c.bump(by: 5) == 16 && c.log.count == 2 && c.log[1] == "bump 5", "class reference semantics and defaults")

    hostCheck(Dir.up.opposite() == .down && Dir.left.opposite() == Dir.right, "enum methods")
    hostCheck(Dir.up.rawValue == 1 && Dir.right.rawValue == 4 && Dir(rawValue: 3) == .left && Dir(rawValue: 9) == nil, "enum raw values")
    hostCheck(Dir.allCases.count == 4 && Dir.up.isVertical && !Dir.left.isVertical, "allCases and computed enum property")
    var lvl = Level.easy
    lvl = .hard
    switch lvl {
    case .easy: hostCheck(false, "switch on enum")
    case .hard: hostCheck(true, "switch on enum")
    }
    var out = ""
    for d in Dir.allCases { out += "\(d)" }
    hostCheck(out == "updownleftright", "enum in string interpolation")
}

var stored: () -> Int = { 0 }

func testClosures() {
    hostCheck(apply({ $0 + 1 }, to: 4) == 5, "closure argument")
    hostCheck(apply({ (x: Int) -> Int in x * x }, to: 6) == 36, "closure with a signature")
    var calls = 0
    twice { calls += 1 }
    hostCheck(calls == 2, "closure changing a local through a function parameter")
    let base = 10
    let adder = { (x: Int) -> Int in x + base }
    hostCheck(adder(5) == 15, "closure capturing a local")
    let fs: [(Int) -> Int] = [{ $0 + 1 }, { $0 * 2 }]
    hostCheck(fs[0](5) == 6 && fs[1](5) == 10, "array of closures")
    func local(_ x: Int) -> Int { x * 3 }
    hostCheck(local(4) == 12, "nested function")
}

func testFlow() {
    var r = 0
    for i in 0..<3 { r += i }
    hostCheck(r == 3, "for")
    var n = 0
    repeat { n += 1 } while n < 3
    hostCheck(n == 3, "repeat while")
    var s = ""
    switch 5 { case 1...3: s = "low"; case 4, 5: s = "mid"; default: s = "high" }
    hostCheck(s == "mid", "switch with ranges and lists")
    switch "go" { case "stop": s = "s"; case "go": s = "g"; default: s = "?" }
    hostCheck(s == "g", "switch on strings")
    let tern = n > 2 ? "big" : "small"
    hostCheck(tern == "big", "ternary")
    var k = 0
    while true { k += 1; if k == 4 { break }; if k < 2 { continue } }
    hostCheck(k == 4, "break and continue")
}

protocol Shape {
    var area: Int { get }
    func scaled(by k: Int) -> Int
    mutating func grow()
}

struct Sq: Shape {
    var side: Int
    var area: Int { side * side }
    func scaled(by k: Int) -> Int { area * k }
    mutating func grow() { side += 1 }
}

struct Rect: Shape {
    var w: Int
    var h: Int
    var area: Int { w * h }
    func scaled(by k: Int) -> Int { area * k }
    mutating func grow() { w += 1; h += 1 }
}

final class Disc: Shape {
    var r = 1
    var area: Int { r * 3 }
    func scaled(by k: Int) -> Int { area * k }
    func grow() { r += 1 }
}

func totalArea(_ shapes: [Shape]) -> Int { shapes.reduce(0) { $0 + $1.area } }

enum Cmd {
    case move(dx: Int, dy: Int)
    case say(String)
    case stop

    func describe() -> String {
        switch self {
        case .move(let dx, let dy): return "move \(dx),\(dy)"
        case .say(let s): return "say " + s
        case .stop: return "stop"
        }
    }
    var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}

enum Result2 { case ok(Int), fail(String) }

func firstWord(_ r: Result2) -> String {
    guard case .ok(let n) = r else { return "failed" }
    return "ok \(n)"
}

func testProtocols() {
    let shapes: [Shape] = [Sq(side: 2), Rect(w: 2, h: 5), Disc()]
    hostCheck(totalArea(shapes) == 4 + 10 + 3, "protocol values in an array")
    hostCheck(shapes[0].scaled(by: 3) == 12 && shapes[1].area == 10, "protocol method and property calls")
    var s: Shape = Sq(side: 1)
    s.grow()
    hostCheck(s.area == 4, "mutating through a protocol value")
    let d = Disc()
    var e: Shape = d
    e.grow()
    hostCheck(d.r == 2 && e.area == 6, "class instances stay shared inside a protocol value")
    var mixed: [Shape] = []
    mixed.append(Rect(w: 1, h: 1))
    mixed.append(Sq(side: 3))
    hostCheck(totalArea(mixed) == 10, "appending conforming types to [Protocol]")
}

func testPayloadEnums() {
    let cmds: [Cmd] = [.move(dx: 1, dy: 2), .say("hi"), .stop, Cmd.move(dx: -3, dy: 0)]
    hostCheck(cmds[0].describe() == "move 1,2" && cmds[1].describe() == "say hi" && cmds[2].describe() == "stop", "enum with values: switch and bindings")
    hostCheck(cmds[3].describe() == "move -3,0", "qualified constructor")
    hostCheck(cmds[0].isMove && !cmds[2].isMove, "if case without bindings")
    var moved = 0
    for c in cmds { if case .move(let dx, _) = c { moved += dx } }
    hostCheck(moved == -2, "if case let in a loop")
    hostCheck(firstWord(.ok(5)) == "ok 5" && firstWord(.fail("no")) == "failed", "guard case")
    var current = Cmd.stop
    current = .say("x")
    hostCheck(current.describe() == "say x", "assigning a case with a value")
}

func testDictionaries() {
    var d = ["a": 1, "b": 2]
    d["c"] = 3
    hostCheck(d.count == 3 && d["a"] == 1 && d["z"] == nil, "dictionary subscript get and set")
    d["a"] = nil
    hostCheck(d.count == 2 && d["a"] == nil, "removing with nil")
    d["x", default: 0] += 5
    d["b", default: 0] += 10
    hostCheck(d["x"] == 5 && d["b"] == 12, "default: subscripts")
    hostCheck(d.keys.sorted() == ["b", "c", "x"] && d.values.reduce(0, +) == 20, "keys and values")
    var total = 0
    var names = ""
    for (k, v) in d { total += v; names += k }
    hostCheck(total == 20 && names.count == 3, "for (key, value) in dict")
    var counts: [String: Int] = [:]
    for w in ["a", "b", "a", "c", "a"] { counts[w, default: 0] += 1 }
    hostCheck(counts["a"] == 3 && counts["b"] == 1 && counts.count == 3, "counting with a dictionary")
    hostCheck(counts.removeValue(forKey: "a") == 3 && counts["a"] == nil, "removeValue")
    var ids: [Int: String] = [1: "one"]
    ids[2] = "two"
    hostCheck((ids[2] ?? "?") == "two" && (ids[9] ?? "?") == "?", "Int keys and ?? on a lookup")
    let copy = ids
    ids[3] = "three"
    hostCheck(copy.count == 2 && ids.count == 3, "dictionary value semantics")
}

struct Stack<T> {
    var items: [T] = []
    mutating func push(_ x: T) { items.append(x) }
    mutating func pop() -> T? { items.popLast() }
    var count: Int { items.count }
}

func firstOf<T>(_ a: [T], _ fallback: T) -> T { a.isEmpty ? fallback : a[0] }
func pick<T>(_ a: T, _ b: T, _ first: Bool) -> T { first ? a : b }

struct Pair<A, B> {
    var a: A
    var b: B
}

func testGenerics() {
    var s = Stack<Int>()
    s.push(3); s.push(4)
    hostCheck(s.count == 2 && s.pop() == 4 && s.count == 1, "generic struct Stack<Int>")
    var names = Stack<String>()
    names.push("x")
    hostCheck(names.pop() == "x" && names.pop() == nil, "generic struct, second specialisation")
    hostCheck(firstOf([7, 8], 0) == 7 && firstOf([String](), "none") == "none", "generic function inference")
    hostCheck(pick("a", "b", false) == "b" && pick(1.5, 2.5, true) == 1.5, "generic function, several types")
    let p = Pair(a: 1, b: "one")
    hostCheck(p.a == 1 && p.b == "one", "multi-parameter generic inferred from init")
}

func appOnStart() {
    testGenerics()
    testProtocols()
    testPayloadEnums()
    testDictionaries()
    testBasics()
    testOptionals()
    testArrays()
    testTypes()
    testClosures()
    testFlow()
}
