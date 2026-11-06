import Foundation

/// A labelled, coloured rectangle drawn behind nodes to group them (the node editor's "boxes").
nonisolated struct GraphBox: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var x: Double, y: Double, width: Double, height: Double
    /// One of `GraphBox.palette`.
    var colour: String

    static let palette = ["blue", "green", "orange", "purple", "red", "gray"]
    static func make(x: Double, y: Double) -> GraphBox {
        GraphBox(id: UUID().uuidString, title: "Group", x: x, y: y, width: 420, height: 260, colour: "blue")
    }
}

// MARK: Layout

nonisolated extension NodeGraph {
    static let nodeWidth = 220.0

    /// Matches the editor's fixed card geometry (header + parameter rows + port rows + padding).
    func nodeHeight(_ n: GraphNode) -> Double {
        26 + Double(n.kind.params.count) * 30 + Double(max(n.kind.inputs.count, n.kind.outputs.count)) * 28 + 8
    }

    /// Tidies the graph: every wire runs left to right, value nodes sit just before whatever uses them, each
    /// event's tree is its own block, and nodes in a column are ordered to keep wires short.
    mutating func cleanUp() {
        guard !nodes.isEmpty else { return }
        var preds: [String: [String]] = [:], succs: [String: [String]] = [:]
        for e in edges where e.fromNode != e.toNode {
            preds[e.toNode, default: []].append(e.fromNode)
            succs[e.fromNode, default: []].append(e.toNode)
        }
        // Longest-path layers (cycle-safe).
        var layer: [String: Int] = [:]
        func depth(_ id: String, _ visiting: inout Set<String>) -> Int {
            if let l = layer[id] { return l }
            guard visiting.insert(id).inserted else { return 0 }
            let d = (preds[id] ?? []).map { depth($0, &visiting) + 1 }.max() ?? 0
            visiting.remove(id)
            layer[id] = d
            return d
        }
        for n in nodes { var v = Set<String>(); _ = depth(n.id, &v) }
        // Pull value nodes (no incoming wires) right up against their earliest user.
        for n in nodes.sorted(by: { (layer[$0.id] ?? 0) > (layer[$1.id] ?? 0) }) where !n.kind.isEvent && (preds[n.id] ?? []).isEmpty {
            if let m = (succs[n.id] ?? []).compactMap({ layer[$0] }).min(), m - 1 > (layer[n.id] ?? 0) { layer[n.id] = m - 1 }
        }
        // Connected blocks.
        var parent: [String: String] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.id) })
        func find(_ a: String) -> String { var x = a; while parent[x] != x { parent[x] = parent[parent[x]!]!; x = parent[x]! }; return x }
        for e in edges where parent[e.fromNode] != nil && parent[e.toNode] != nil { parent[find(e.fromNode)] = find(e.toNode) }
        var blocks: [String: [GraphNode]] = [:]
        for n in nodes { blocks[find(n.id), default: []].append(n) }
        let ordered = blocks.values.sorted { ($0.map(\.y).min() ?? 0, $0.map(\.x).min() ?? 0) < ($1.map(\.y).min() ?? 0, $1.map(\.x).min() ?? 0) }

        let colGap = 90.0, rowGap = 22.0, blockGap = 70.0
        var top = 40.0
        var pos: [String: (Double, Double)] = [:]
        for block in ordered {
            let columns = Dictionary(grouping: block, by: { layer[$0.id] ?? 0 })
            var yOf: [String: Double] = [:]
            var blockBottom = top
            for col in columns.keys.sorted() {
                // Order by the average height of the wires coming in (original y for the first column).
                let items = columns[col]!.sorted { a, b in
                    func key(_ n: GraphNode) -> Double {
                        let p = (preds[n.id] ?? []).compactMap { yOf[$0] }
                        return p.isEmpty ? n.y : p.reduce(0, +) / Double(p.count)
                    }
                    return (key(a), a.x) < (key(b), b.x)
                }
                var y = top
                for n in items {
                    yOf[n.id] = y
                    pos[n.id] = (40 + Double(col) * (Self.nodeWidth + colGap), y)
                    y += nodeHeight(n) + rowGap
                }
                blockBottom = max(blockBottom, y - rowGap)
            }
            top = blockBottom + blockGap
        }
        for i in nodes.indices { if let p = pos[nodes[i].id] { nodes[i].x = p.0; nodes[i].y = p.1 } }
    }
}

// MARK: Analysis

/// One kind of clean-up or speed-up the analyser can find, and the edit that performs it.
nonisolated struct GraphPass {
    var id: String
    var title: String
    var explanation: String
    /// Edits the graph; returns the ids of the nodes it removed or changed (empty = nothing to do).
    var run: (inout NodeGraph) -> [String]
}

nonisolated struct GraphSuggestion: Identifiable {
    var id: String
    var title: String
    var detail: String
    var nodes: [String]
}

nonisolated extension NodeGraph {
    private func isExecNode(_ n: GraphNode) -> Bool {
        n.kind.inputs.contains { $0.type == .exec } || n.kind.outputs.contains { $0.type == .exec }
    }

    private func numberValue(of n: GraphNode?) -> Double? {
        guard let n, n.kind == .number else { return nil }
        return Double((n.params["value"] ?? "0").trimmingCharacters(in: .whitespaces))
    }

    /// The numeric value feeding input `port`: a wired Number node, or the literal typed on the node.
    private func constantInput(_ n: GraphNode, _ port: String) -> Double? {
        if let e = edges.first(where: { $0.toNode == n.id && $0.toPort == port }) { return numberValue(of: node(e.fromNode)) }
        return Double((n.params[port] ?? "0").trimmingCharacters(in: .whitespaces))
    }

    static let passes: [GraphPass] = [
        GraphPass(id: "unreachable", title: "Remove blocks that never run",
                  explanation: "Action nodes that no event can reach (nothing wires into them from an event) are never executed.") { g in
            var reached = Set<String>()
            var stack = g.nodes.filter { $0.kind.isEvent }.map(\.id)
            while let id = stack.popLast() {
                guard reached.insert(id).inserted else { continue }
                stack += g.edges.filter { $0.fromNode == id && g.node($0.toNode).map(g.isExecNode) == true && g.exec($0) }.map(\.toNode)
            }
            let dead = g.nodes.filter { g.isExecNode($0) && !$0.kind.isEvent && !reached.contains($0.id) }.map(\.id)
            for id in dead { g.remove(node: id) }
            return dead
        },
        GraphPass(id: "emptyEvents", title: "Remove events that do nothing",
                  explanation: "Events with nothing connected to them add no behaviour.") { g in
            let empty = g.nodes.filter { n in n.kind.isEvent && !g.edges.contains { e in e.fromNode == n.id } }.map(\.id)
            for id in empty { g.remove(node: id) }
            return empty
        },
        GraphPass(id: "unusedFunctions", title: "Remove functions that are never called",
                  explanation: "A Define Function that no Call Function uses is dead code.") { g in
            let called = Set(g.nodes.filter { $0.kind == .callFunction }.map { UIDocument.identifier($0.params["function"] ?? "") })
            let dead = g.nodes.filter { $0.kind == .defineFunction && !called.contains(UIDocument.identifier($0.params["name"] ?? "")) }.map(\.id)
            for id in dead { g.remove(node: id) }
            return dead
        },
        GraphPass(id: "constantBranch", title: "Resolve decisions that are always the same",
                  explanation: "A Branch whose condition is a fixed Yes/No always takes one side.") { g in
            var changed: [String] = []
            for b in g.nodes where b.kind == .branch {
                guard let c = g.edges.first(where: { $0.toNode == b.id && $0.toPort == "condition" }), let cn = g.node(c.fromNode), cn.kind == .boolConst,
                      let into = g.edges.first(where: { $0.toNode == b.id && $0.toPort == "in" }) else { continue }
                let taken = (cn.params["value"] ?? "Yes") == "No" ? "false" : "true"
                let takenEdge = g.edges.first { $0.fromNode == b.id && $0.fromPort == taken }
                let after = g.edges.first { $0.fromNode == b.id && $0.fromPort == "regardless" }
                // Only when one of the two chains is empty can the branch be spliced out without merging chains.
                let target: GraphEdge?
                if takenEdge == nil { target = after } else if after == nil { target = takenEdge } else { continue }
                g.edges.removeAll { $0.toNode == b.id || $0.fromNode == b.id }
                if let t = target { g.edges.append(GraphEdge(fromNode: into.fromNode, fromPort: into.fromPort, toNode: t.toNode, toPort: t.toPort)) }
                g.nodes.removeAll { $0.id == b.id }
                changed.append(b.id)
            }
            return changed
        },
        GraphPass(id: "foldMath", title: "Calculate fixed maths ahead of time",
                  explanation: "Maths on numbers that never change is replaced by the result, so the Wii doesn't redo it every frame.") { g in
            var changed: [String] = []
            for n in g.nodes {
                let v: Double?
                switch n.kind {
                case .add, .subtract, .multiply, .divide, .modulo, .minimum, .maximum:
                    guard let a = g.constantInput(n, "a"), let b = g.constantInput(n, "b") else { continue }
                    switch n.kind {
                    case .add: v = a + b
                    case .subtract: v = a - b
                    case .multiply: v = a * b
                    case .divide: v = b == 0 ? 0 : a / b
                    case .modulo: v = b == 0 ? 0 : Double(Int64(a) % Int64(b))
                    case .minimum: v = min(a, b)
                    default: v = max(a, b)
                    }
                case .absolute:
                    guard let a = g.constantInput(n, "a") else { continue }
                    v = abs(a)
                default: continue
                }
                guard let value = v, value.isFinite, let i = g.nodes.firstIndex(where: { $0.id == n.id }) else { continue }
                g.nodes[i].kind = .number
                g.nodes[i].params = ["value": value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)]
                g.edges.removeAll { $0.toNode == n.id }
                changed.append(n.id)
            }
            return changed
        },
        GraphPass(id: "makeSplit", title: "Skip building a vector only to take it apart",
                  explanation: "Split Vector fed straight by Make Vector can use the original x and y numbers.") { g in
            var changed: [String] = []
            for s in g.nodes where s.kind == .splitVector {
                guard let into = g.edges.first(where: { $0.toNode == s.id }), let m = g.node(into.fromNode), m.kind == .makeVector else { continue }
                for port in ["x", "y"] {
                    let users = g.edges.filter { $0.fromNode == s.id && $0.fromPort == port }
                    guard !users.isEmpty else { continue }
                    if let src = g.edges.first(where: { $0.toNode == m.id && $0.toPort == port }) {
                        for u in users { g.edges.append(GraphEdge(fromNode: src.fromNode, fromPort: src.fromPort, toNode: u.toNode, toPort: u.toPort)) }
                    } else {
                        var lit = GraphNode.make(.number, x: s.x, y: s.y)
                        lit.params["value"] = m.params[port] ?? "0"
                        g.nodes.append(lit)
                        for u in users { g.edges.append(GraphEdge(fromNode: lit.id, fromPort: "value", toNode: u.toNode, toPort: u.toPort)) }
                    }
                }
                g.remove(node: s.id)
                changed.append(s.id)
            }
            return changed
        },
        GraphPass(id: "deadValues", title: "Remove value nodes nothing uses",
                  explanation: "Number, variable-read and maths nodes whose result goes nowhere only take up space.") { g in
            var removed: [String] = []
            while true {
                let dead = g.nodes.filter { n in !g.isExecNode(n) && !g.edges.contains { e in e.fromNode == n.id } }.map(\.id)
                if dead.isEmpty { break }
                for id in dead { g.remove(node: id) }
                removed += dead
            }
            return removed
        },
        GraphPass(id: "unusedUnconnected", title: "Remove nodes that aren't connected to anything",
                  explanation: "Action nodes with no wires at all do nothing.") { g in
            let dead = g.nodes.filter { n in !n.kind.isEvent && !g.edges.contains { e in e.fromNode == n.id || e.toNode == n.id } }.map(\.id)
            for id in dead { g.remove(node: id) }
            return dead
        },
        GraphPass(id: "unusedVariables", title: "Remove variables nothing uses",
                  explanation: "Unused variables still take memory (and, in a sprite actor, space in every copy).") { g in
            let used = Set(g.nodes.compactMap { $0.params["variable"] })
            // Shared variables may be used from other files, so they are never "unused" here.
            let dead = g.variables.filter { !$0.global && !used.contains($0.name) }.map(\.name)
            g.variables.removeAll { !$0.global && !used.contains($0.name) }
            return dead
        },
    ]

    private func exec(_ e: GraphEdge) -> Bool {
        node(e.fromNode)?.kind.outputs.first(where: { $0.name == e.fromPort })?.type == .exec
    }

    /// What `passes` would change, one suggestion per pass that has something to do.
    func suggestions() -> [GraphSuggestion] {
        Self.passes.compactMap { pass in
            var copy = self
            let hit = pass.run(&copy)
            guard !hit.isEmpty else { return nil }
            return GraphSuggestion(id: pass.id, title: pass.title, detail: "\(pass.explanation) (\(hit.count) found)", nodes: hit.filter { id in node(id) != nil })
        }
    }

    /// Runs the chosen passes until nothing more changes (one pass can expose work for another).
    @discardableResult
    mutating func perform(_ ids: Set<String>) -> Int {
        var total = 0
        for _ in 0..<6 {
            var round = 0
            for pass in Self.passes where ids.contains(pass.id) { round += pass.run(&self).count }
            total += round
            if round == 0 { break }
        }
        return total
    }

    /// The tidy-ups that never change behaviour, applied automatically before code generation.
    mutating func optimizeForCodegen() {
        perform(Set(Self.passes.map(\.id)).subtracting(["unusedUnconnected"]))
    }
}
