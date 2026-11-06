import Foundation

/// Triangle strips, as RiiStudio makes them for a model's display lists: a Swift port of
/// meshoptimizer's `meshopt_stripify` (Arseny Kapoulkine, MIT licence; after Evans, Skiena and
/// Varshney, "Optimizing Triangle Strips for Fast Rendering", 1996), one of the stripifiers
/// RiiStudio's importer runs. Each strip keeps the winding of the triangles it covers.
nonisolated enum TriangleStrips {
    /// `triangles` (vertex ids, 3 per triangle) as strips: each strip's first three ids are a
    /// triangle, every id after that adds one more, the winding alternating as GX expects.
    static func stripify(_ triangles: [Int], vertexCount: Int) -> [[Int]] {
        precondition(triangles.count % 3 == 0)
        var strips: [[Int]] = []
        var current: [Int] = []
        let capacity = 8
        var buffer: [(Int, Int, Int)] = []
        var offset = 0
        var strip = (0, 0)
        var parity = 0
        // Vertex valence, 8-bit as in meshoptimizer (it only steers the strip-start heuristic).
        var valence = [UInt8](repeating: 0, count: vertexCount)
        for i in triangles { valence[i] &+= 1 }

        func findNext(_ e0: Int, _ e1: Int) -> Int {
            for (i, t) in buffer.enumerated() {
                if e0 == t.0 && e1 == t.1 { return i << 2 | 2 }
                if e0 == t.1 && e1 == t.2 { return i << 2 | 0 }
                if e0 == t.2 && e1 == t.0 { return i << 2 | 1 }
            }
            return -1
        }
        func findFirst() -> Int {
            var index = 0, best = Int.max
            for (i, t) in buffer.enumerated() {
                let va = valence[t.0], vb = valence[t.1], vc = valence[t.2]
                let v = Int((va < vb && va < vc) ? va : (vb < vc ? vb : vc))
                if v < best { index = i; best = v }
            }
            return index
        }

        var next = -1
        while !buffer.isEmpty || offset < triangles.count {
            while buffer.count < capacity && offset < triangles.count {
                buffer.append((triangles[offset], triangles[offset + 1], triangles[offset + 2]))
                offset += 3
            }
            if next >= 0 {
                let i = next >> 2
                let t = buffer[i]
                let v = [t.0, t.1, t.2][next & 3]
                buffer.remove(at: i)
                valence[t.0] &-= 1; valence[t.1] &-= 1; valence[t.2] &-= 1
                // The next triangle along (the edge order flips every step); failing that, swap.
                let cont = findNext(parity != 0 ? strip.1 : v, parity != 0 ? v : strip.1)
                let swap = cont < 0 ? findNext(parity != 0 ? v : strip.0, parity != 0 ? strip.0 : v) : -1
                if cont < 0 && swap >= 0 {
                    // [a b c] => [a b a c]: same winding for the next one.
                    current += [strip.0, v]
                    strip.1 = v
                    next = swap
                } else {
                    current.append(v)
                    strip = (strip.1, v)
                    parity ^= 1
                    next = cont
                }
            } else {
                // A new strip: start from the triangle whose least-shared vertex is least shared,
                // turned so that it continues into a triangle still waiting.
                let i = findFirst()
                var (a, b, c) = buffer[i]
                buffer.remove(at: i)
                valence[a] &-= 1; valence[b] &-= 1; valence[c] &-= 1
                let ea = findNext(c, b), eb = findNext(a, c), ec = findNext(b, a)
                var mine = Int.max
                if ea >= 0 && mine > ea { mine = ea }
                if eb >= 0 && mine > eb { mine = eb }
                if ec >= 0 && mine > ec { mine = ec }
                if ea == mine { next = ea }
                else if eb == mine { (a, b, c) = (b, c, a); next = eb }
                else if ec == mine { (a, b, c) = (c, a, b); next = ec }
                else { next = -1 }
                if !current.isEmpty { strips.append(current) }
                current = [a, b, c]
                strip = (b, c)
                parity = 1
            }
        }
        if !current.isEmpty { strips.append(current) }
        return strips
    }

    /// The triangles a strip draws, in its own winding, leaving out the degenerate ones a swap makes.
    static func triangles(of strip: [Int]) -> [(Int, Int, Int)] {
        guard strip.count >= 3 else { return [] }
        var out: [(Int, Int, Int)] = []
        for i in 2..<strip.count {
            var (a, b) = (strip[i - 2], strip[i - 1])
            let c = strip[i]
            if (i - 2) & 1 == 1 { swap(&a, &b) }
            if a != b && a != c && b != c { out.append((a, b, c)) }
        }
        return out
    }
}
