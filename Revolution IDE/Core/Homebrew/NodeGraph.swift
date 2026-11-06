import Foundation

/// The node editor's file (`.wiinodes`): a Blueprint-style graph that `NodeCodegen` turns into C.
/// White "exec" wires run top to bottom; coloured data wires carry numbers, text and booleans.
nonisolated enum PortType: String, Codable {
    case exec, number, text, bool
    /// A 2D point or direction: x and y numbers.
    case vector
    /// A red/green/blue colour, each 0...255.
    case colour
    /// A rectangle: x, y, width and height.
    case bounds
}

nonisolated struct PortSpec {
    var name: String
    var type: PortType
    /// Shown on the node; defaults to the name.
    var label: String { name == "in" ? "" : name }
}

nonisolated enum ParamKind {
    case text, number
    case widget            // a widget in the project's .wiiui
    case sprite            // an image in the project's assets/
    case sound             // a sound in the project's assets/
    case variable(PortType)
    case function          // one of the graph's Define Function nodes
    case actor             // a sprite actor: another .wiinodes file marked as one
    case screen            // one of the project's .wiiui screens
    case music             // a .brstm in the project's assets/
    case colour            // a colour picker that writes the node's r, g and b
    case choice([String])
    case toggle            // a tick box stored as "Yes" / "No"
}

nonisolated struct ParamSpec {
    var key: String
    var label: String
    var kind: ParamKind
    var defaultValue: String
}

nonisolated enum NodeKind: String, Codable, CaseIterable, Identifiable {
    // Case order is menu order, matching `Category` order: how a program starts, then control, then data in,
    // data out, and finally what is drawn. Each category lists a Get next to its Set.
    case onStart, onFrame, onDraw, onButton, onWiimote
    case branch, repeatLoop
    case exitApp
    case defineFunction, callFunction
    case buttonHeld, buttonPressed, stickX, stickY, pointerX, pointerY
    case getNumberVar, setNumberVar, getTextVar, setTextVar, getBoolVar, setBoolVar, toggleBoolVar, getVectorVar, setVectorVar, getBoundsVar, setBoundsVar, setBoundsFromVectors
    case number, textConst, boolConst, frameCount, screenSize, makeVector, splitVector, makeBounds, makeBoundsFromVectors, makeColour
    case add, subtract, multiply, divide, modulo, absolute, minimum, maximum, random, sine, cosine, tangent
    case addVectors, subtractVectors, scaleVector, vectorLength
    case compare, and, or, not, overlaps
    case textEquals, join, numberToText, boolToText, vectorToText, colourToText
    case getText, setText, setVisible, setColor, getWidgetPosition, setWidgetPosition, moveWidget, getWidgetSize, switchScreen
    case spawnSprite, onSpawn, onUpdate, getSelfPosition, setSelfPosition, moveSelf, destroySelf, touchingSprite, destroyTouching, destroyAll, boundsInSprite, spritesOverlap
    case drawRect, drawText, drawSprite, playSound, playMusic, stopMusic

    var id: String { rawValue }

    enum Category: String, CaseIterable { case events = "Events", flow = "Flow", functions = "Functions", input = "Input", variables = "Variables", values = "Values", math = "Math & Logic", text = "Text", widgets = "Widgets", sprites = "Sprites", draw = "Drawing & Sound" }

    var category: Category {
        switch self {
        case .onStart, .onFrame, .onDraw, .onButton, .onWiimote: return .events
        case .branch, .repeatLoop, .exitApp: return .flow
        case .defineFunction, .callFunction: return .functions
        case .spawnSprite, .onSpawn, .onUpdate, .getSelfPosition, .setSelfPosition, .moveSelf, .destroySelf, .touchingSprite, .destroyTouching, .destroyAll, .boundsInSprite, .spritesOverlap: return .sprites
        case .getText, .setText, .setVisible, .setColor, .getWidgetPosition, .setWidgetPosition, .moveWidget, .getWidgetSize, .switchScreen: return .widgets
        case .getNumberVar, .setNumberVar, .getTextVar, .setTextVar, .getBoolVar, .setBoolVar, .toggleBoolVar, .getVectorVar, .setVectorVar, .getBoundsVar, .setBoundsVar, .setBoundsFromVectors: return .variables
        case .drawRect, .drawText, .drawSprite, .playSound, .playMusic, .stopMusic: return .draw
        case .buttonHeld, .buttonPressed, .stickX, .stickY, .pointerX, .pointerY: return .input
        case .number, .textConst, .boolConst, .frameCount, .makeVector, .splitVector, .makeBounds, .makeBoundsFromVectors, .makeColour, .screenSize: return .values
        case .add, .subtract, .multiply, .divide, .modulo, .compare, .and, .or, .not, .random, .minimum, .maximum, .absolute, .overlaps, .addVectors, .subtractVectors, .scaleVector, .vectorLength, .sine, .cosine, .tangent: return .math
        case .textEquals, .numberToText, .boolToText, .vectorToText, .colourToText, .join: return .text
        }
    }

    var title: String {
        switch self {
        case .onStart: return "On Start"
        case .onFrame: return "On Every Frame"
        case .onDraw: return "On Draw"
        case .onButton: return "On Button Pressed"
        case .onWiimote: return "On Wii Remote Button"
        case .branch: return "Branch"
        case .repeatLoop: return "Repeat"
        case .setText: return "Set Text"
        case .setVisible: return "Set Visible"
        case .setColor: return "Set Colour"
        case .setNumberVar: return "Set Number"
        case .setTextVar: return "Set Text Variable"
        case .setBoolVar: return "Set Boolean"
        case .toggleBoolVar: return "Toggle"
        case .setVectorVar: return "Set Vector"
        case .makeVector: return "Make Vector"
        case .makeColour: return "Colour"
        case .splitVector: return "Split Vector"
        case .getVectorVar: return "Get Vector"
        case .getBoundsVar: return "Get Bounds"
        case .setBoundsVar: return "Set Bounds"
        case .makeBounds: return "Make Bounds"
        case .makeBoundsFromVectors: return "Make Bounds (Vectors)"
        case .setBoundsFromVectors: return "Set Bounds (Vectors)"
        case .boundsInSprite: return "Bounds In Sprite"
        case .spritesOverlap: return "Sprites Overlap"
        case .addVectors: return "Add Vectors"
        case .subtractVectors: return "Subtract Vectors"
        case .scaleVector: return "Scale Vector"
        case .vectorLength: return "Vector Length"
        case .exitApp: return "Exit App"
        case .screenSize: return "Get Screen Size"
        case .spawnSprite: return "Spawn Sprite"
        case .onSpawn: return "On Spawn"
        case .onUpdate: return "On Update"
        case .getSelfPosition: return "Get Self Position"
        case .setSelfPosition: return "Set Self Position"
        case .moveSelf: return "Move Self"
        case .destroySelf: return "Destroy Self"
        case .touchingSprite: return "Touching Sprite"
        case .destroyTouching: return "Destroy Touching Sprites"
        case .destroyAll: return "Destroy All"
        case .defineFunction: return "Define Function"
        case .callFunction: return "Call Function"
        case .sine: return "Sine"
        case .cosine: return "Cosine"
        case .tangent: return "Tangent"
        case .number: return "Number"
        case .textConst: return "Text"
        case .boolConst: return "Boolean"
        case .getNumberVar: return "Get Number"
        case .getTextVar: return "Get Text Variable"
        case .getBoolVar: return "Get Boolean"
        case .getText: return "Get Widget Text"
        case .getWidgetPosition: return "Get Widget Position"
        case .getWidgetSize: return "Get Widget Size"
        case .setWidgetPosition: return "Set Widget Position"
        case .moveWidget: return "Move Widget"
        case .switchScreen: return "Switch UI Screen"
        case .frameCount: return "Frame Count"
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .multiply: return "Multiply"
        case .divide: return "Divide"
        case .modulo: return "Remainder"
        case .compare: return "Compare"
        case .textEquals: return "Text Equals"
        case .and: return "And"
        case .or: return "Or"
        case .not: return "Not"
        case .numberToText: return "Number to Text"
        case .boolToText: return "Boolean to Text"
        case .vectorToText: return "Vector to Text"
        case .colourToText: return "Colour to Text"
        case .join: return "Join Text"
        case .random: return "Random Number"
        case .minimum: return "Smaller Of"
        case .maximum: return "Larger Of"
        case .absolute: return "Absolute Value"
        case .drawRect: return "Draw Rectangle"
        case .drawText: return "Draw Text"
        case .drawSprite: return "Draw Sprite"
        case .playSound: return "Play Sound"
        case .playMusic: return "Play Music"
        case .stopMusic: return "Stop Music"
        case .buttonHeld: return "Button Held"
        case .buttonPressed: return "Button Pressed"
        case .stickX: return "Stick Left/Right"
        case .stickY: return "Stick Up/Down"
        case .pointerX: return "Pointer X"
        case .pointerY: return "Pointer Y"
        case .overlaps: return "Rectangles Overlap"
        }
    }

    var isEvent: Bool { category == .events || self == .defineFunction || self == .onSpawn || self == .onUpdate }

    var inputs: [PortSpec] {
        let exec = PortSpec(name: "in", type: .exec)
        switch self {
        case .onStart, .onFrame, .onDraw, .onButton, .onWiimote, .defineFunction, .onSpawn, .onUpdate, .getSelfPosition, .touchingSprite, .screenSize, .number, .textConst, .boolConst,
             .getNumberVar, .getTextVar, .getBoolVar, .getVectorVar, .getBoundsVar, .spritesOverlap, .getText, .getWidgetPosition, .getWidgetSize, .frameCount,
             .buttonHeld, .buttonPressed, .stickX, .stickY, .pointerX, .pointerY: return []
        case .drawRect:
            return [exec, PortSpec(name: "position", type: .vector), PortSpec(name: "size", type: .vector),
                    PortSpec(name: "colour", type: .colour), PortSpec(name: "alpha", type: .number)]
        case .drawText:
            return [exec, PortSpec(name: "text", type: .text), PortSpec(name: "position", type: .vector),
                    PortSpec(name: "size", type: .number), PortSpec(name: "colour", type: .colour)]
        case .drawSprite: return [exec, PortSpec(name: "position", type: .vector)]
        case .makeColour: return ["r", "g", "b"].map { PortSpec(name: $0, type: .number) }
        case .playSound, .playMusic, .stopMusic: return [exec]
        case .overlaps:
            return ["ax", "ay", "aw", "ah", "bx", "by", "bw", "bh"].map { PortSpec(name: $0, type: .number) }
        case .minimum, .maximum: return [PortSpec(name: "a", type: .number), PortSpec(name: "b", type: .number)]
        case .absolute: return [PortSpec(name: "a", type: .number)]
        case .branch: return [exec, PortSpec(name: "condition", type: .bool)]
        case .repeatLoop: return [exec, PortSpec(name: "count", type: .number)]
        case .setText: return [exec, PortSpec(name: "text", type: .text)]
        case .setVisible: return [exec, PortSpec(name: "visible", type: .bool)]
        case .setColor: return [exec, PortSpec(name: "colour", type: .colour)]
        case .setNumberVar: return [exec, PortSpec(name: "value", type: .number)]
        case .setTextVar: return [exec, PortSpec(name: "value", type: .text)]
        case .setBoolVar: return [exec, PortSpec(name: "value", type: .bool)]
        case .exitApp, .toggleBoolVar, .callFunction, .switchScreen, .destroySelf, .destroyTouching, .destroyAll: return [exec]
        case .spawnSprite, .setSelfPosition: return [exec, PortSpec(name: "position", type: .vector)]
        case .moveSelf: return [exec, PortSpec(name: "by", type: .vector)]
        case .sine, .cosine, .tangent: return [PortSpec(name: "angle", type: .number)]
        case .setVectorVar: return [exec, PortSpec(name: "value", type: .vector)]
        case .setBoundsVar: return [exec, PortSpec(name: "value", type: .bounds)]
        case .setBoundsFromVectors: return [exec, PortSpec(name: "position", type: .vector), PortSpec(name: "size", type: .vector)]
        case .makeBoundsFromVectors: return [PortSpec(name: "position", type: .vector), PortSpec(name: "size", type: .vector)]
        case .makeBounds: return ["x", "y", "width", "height"].map { PortSpec(name: $0, type: .number) }
        case .boundsInSprite: return [PortSpec(name: "bounds", type: .bounds)]
        case .setWidgetPosition: return [exec, PortSpec(name: "position", type: .vector)]
        case .moveWidget: return [exec, PortSpec(name: "by", type: .vector)]
        case .makeVector: return [PortSpec(name: "x", type: .number), PortSpec(name: "y", type: .number)]
        case .splitVector, .vectorLength: return [PortSpec(name: "vector", type: .vector)]
        case .addVectors, .subtractVectors: return [PortSpec(name: "a", type: .vector), PortSpec(name: "b", type: .vector)]
        case .scaleVector: return [PortSpec(name: "vector", type: .vector), PortSpec(name: "by", type: .number)]
        case .add, .subtract, .multiply, .divide, .modulo, .compare: return [PortSpec(name: "a", type: .number), PortSpec(name: "b", type: .number)]
        case .textEquals, .join: return [PortSpec(name: "a", type: .text), PortSpec(name: "b", type: .text)]
        case .and, .or: return [PortSpec(name: "a", type: .bool), PortSpec(name: "b", type: .bool)]
        case .not: return [PortSpec(name: "a", type: .bool)]
        case .numberToText: return [PortSpec(name: "number", type: .number)]
        case .boolToText: return [PortSpec(name: "boolean", type: .bool)]
        case .vectorToText: return [PortSpec(name: "vector", type: .vector)]
        case .colourToText: return [PortSpec(name: "colour", type: .colour)]
        case .random: return [PortSpec(name: "min", type: .number), PortSpec(name: "max", type: .number)]
        }
    }

    var outputs: [PortSpec] {
        let then = PortSpec(name: "then", type: .exec)
        switch self {
        case .onStart, .onFrame, .onDraw, .onButton, .onWiimote, .setText, .setVisible, .setColor, .setNumberVar, .setTextVar, .setBoolVar, .toggleBoolVar, .setVectorVar, .setBoundsVar, .setBoundsFromVectors, .setWidgetPosition, .moveWidget, .switchScreen, .defineFunction, .callFunction, .spawnSprite, .onSpawn, .onUpdate, .setSelfPosition, .moveSelf, .destroyTouching, .destroyAll,
             .drawRect, .drawText, .drawSprite, .playSound, .playMusic, .stopMusic: return [then]
        case .branch: return [PortSpec(name: "true", type: .exec), PortSpec(name: "false", type: .exec), PortSpec(name: "regardless", type: .exec)]
        case .repeatLoop: return [PortSpec(name: "body", type: .exec), PortSpec(name: "done", type: .exec), PortSpec(name: "index", type: .number)]
        case .exitApp, .destroySelf: return []
        case .getSelfPosition: return [PortSpec(name: "vector", type: .vector)]
        case .touchingSprite, .boundsInSprite, .spritesOverlap: return [PortSpec(name: "value", type: .bool)]
        case .makeBounds, .makeBoundsFromVectors, .getBoundsVar: return [PortSpec(name: "bounds", type: .bounds)]
        case .number, .getNumberVar, .frameCount, .add, .subtract, .multiply, .divide, .modulo, .random,
             .minimum, .maximum, .absolute, .stickX, .stickY, .pointerX, .pointerY, .vectorLength, .sine, .cosine, .tangent: return [PortSpec(name: "value", type: .number)]
        case .makeColour: return [PortSpec(name: "colour", type: .colour)]
        case .makeVector, .screenSize, .getVectorVar, .getWidgetPosition, .getWidgetSize, .addVectors, .subtractVectors, .scaleVector: return [PortSpec(name: "vector", type: .vector)]
        case .splitVector: return [PortSpec(name: "x", type: .number), PortSpec(name: "y", type: .number)]
        case .textConst, .getTextVar, .getText, .numberToText, .boolToText, .vectorToText, .colourToText, .join: return [PortSpec(name: "text", type: .text)]
        case .boolConst, .getBoolVar, .compare, .textEquals, .and, .or, .not, .buttonHeld, .buttonPressed, .overlaps: return [PortSpec(name: "value", type: .bool)]
        }
    }

    /// What an unwired data input holds until you type something else.
    var inputDefaults: [String: String] {
        switch self {
        case .scaleVector: return ["by": "1"]
        case .setColor: return ["colour": "255, 255, 255"]
        case .makeBounds: return ["width": "32", "height": "32"]
        case .makeBoundsFromVectors, .setBoundsFromVectors: return ["size": "32, 32"]
        case .boundsInSprite: return ["bounds": "0, 0, 32, 32"]
        case .drawRect: return ["size": "32, 32", "colour": "255, 255, 255", "alpha": "255"]
        case .drawText: return ["text": "Hello", "size": "24", "colour": "255, 255, 255"]
        case .makeColour: return ["r": "255", "g": "255", "b": "255"]
        default: return [:]
        }
    }

    static let wiimoteButtons = ["A", "B", "1", "2", "Plus", "Minus", "Up", "Down", "Left", "Right"]

    var params: [ParamSpec] {
        switch self {
        case .onButton, .setText, .setVisible, .setColor, .getText, .getWidgetPosition, .setWidgetPosition, .moveWidget, .getWidgetSize:
            return [ParamSpec(key: "widget", label: "Widget", kind: .widget, defaultValue: "")]
        case .onWiimote:
            return [ParamSpec(key: "button", label: "Button", kind: .choice(NodeKind.wiimoteButtons), defaultValue: "A")]
        case .buttonHeld, .buttonPressed:
            return [ParamSpec(key: "button", label: "Button", kind: .choice(NodeKind.wiimoteButtons), defaultValue: "A"),
                    ParamSpec(key: "player", label: "Player", kind: .choice(["1", "2", "3", "4"]), defaultValue: "1")]
        case .stickX, .stickY: return [ParamSpec(key: "player", label: "Player", kind: .choice(["1", "2", "3", "4"]), defaultValue: "1")]
        case .spawnSprite, .touchingSprite, .destroyTouching, .destroyAll: return [ParamSpec(key: "actor", label: "Sprite", kind: .actor, defaultValue: "")]
        case .switchScreen: return [ParamSpec(key: "screen", label: "Screen", kind: .screen, defaultValue: "")]
        case .makeColour: return [ParamSpec(key: "picker", label: "Pick", kind: .colour, defaultValue: "")]
        case .drawSprite: return [ParamSpec(key: "sprite", label: "Sprite", kind: .sprite, defaultValue: "")]
        case .playSound: return [ParamSpec(key: "sound", label: "Sound", kind: .sound, defaultValue: "")]
        case .playMusic: return [ParamSpec(key: "music", label: "Music", kind: .music, defaultValue: ""),
                                 ParamSpec(key: "loop", label: "Loop", kind: .choice(["Yes", "No"]), defaultValue: "Yes")]
        case .setNumberVar, .getNumberVar: return [ParamSpec(key: "variable", label: "Variable", kind: .variable(.number), defaultValue: "")]
        case .setTextVar, .getTextVar: return [ParamSpec(key: "variable", label: "Variable", kind: .variable(.text), defaultValue: "")]
        case .setVectorVar, .getVectorVar: return [ParamSpec(key: "variable", label: "Variable", kind: .variable(.vector), defaultValue: "")]
        case .setBoundsVar, .getBoundsVar, .setBoundsFromVectors: return [ParamSpec(key: "variable", label: "Variable", kind: .variable(.bounds), defaultValue: "")]
        case .boundsInSprite: return [ParamSpec(key: "actor", label: "Sprite", kind: .actor, defaultValue: ""),
                                      ParamSpec(key: "inside", label: "Fully inside", kind: .toggle, defaultValue: "No")]
        case .spritesOverlap: return [ParamSpec(key: "actor", label: "Sprite A", kind: .actor, defaultValue: ""), ParamSpec(key: "actor2", label: "Sprite B", kind: .actor, defaultValue: ""),
                                         ParamSpec(key: "inside", label: "A fully inside B", kind: .toggle, defaultValue: "No")]
        case .setBoolVar, .toggleBoolVar, .getBoolVar: return [ParamSpec(key: "variable", label: "Variable", kind: .variable(.bool), defaultValue: "")]
        case .defineFunction: return [ParamSpec(key: "name", label: "Name", kind: .text, defaultValue: "myFunction")]
        case .callFunction: return [ParamSpec(key: "function", label: "Function", kind: .function, defaultValue: "")]
        case .sine, .cosine, .tangent: return [ParamSpec(key: "unit", label: "Angle in", kind: .choice(["Degrees", "Radians"]), defaultValue: "Degrees")]
        case .number: return [ParamSpec(key: "value", label: "Value", kind: .number, defaultValue: "0")]
        case .textConst: return [ParamSpec(key: "text", label: "Text", kind: .text, defaultValue: "Hello")]
        case .boolConst: return [ParamSpec(key: "value", label: "Value", kind: .choice(["Yes", "No"]), defaultValue: "Yes")]
        case .compare: return [ParamSpec(key: "op", label: "Is", kind: .choice(["==", "!=", "<", ">", "<=", ">="]), defaultValue: "==")]
        default: return []
        }
    }
}

nonisolated struct GraphNode: Codable, Identifiable, Equatable {
    var id: String
    var kind: NodeKind
    var x: Double
    var y: Double
    /// Parameter values, plus literal values for unconnected data inputs (keyed by port name).
    var params: [String: String]

    static func make(_ kind: NodeKind, x: Double, y: Double) -> GraphNode {
        var p: [String: String] = [:]
        for spec in kind.params { p[spec.key] = spec.defaultValue }
        for (k, v) in kind.inputDefaults { p[k] = v }
        return GraphNode(id: UUID().uuidString, kind: kind, x: x, y: y, params: p)
    }
}

nonisolated struct GraphEdge: Codable, Hashable {
    var fromNode: String, fromPort: String
    var toNode: String, toPort: String
}

nonisolated struct GraphVariable: Codable, Identifiable, Equatable {
    var name: String
    var type: PortType      // .number, .text, .bool or .vector ("x, y")
    var initial: String
    /// Shared by every node file in the project (the program and all sprite actors) instead of belonging to this graph.
    var global = false
    var id: String { name }
}

nonisolated extension GraphVariable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(PortType.self, forKey: .type)
        initial = try c.decode(String.self, forKey: .initial)
        global = try c.decodeIfPresent(Bool.self, forKey: .global) ?? false
    }

    /// The C name of a shared variable.
    var globalCName: String { "g_" + UIDocument.identifier(name) }
}

nonisolated struct NodeGraph: Codable, Equatable {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var variables: [GraphVariable] = []
    /// Y counts up from the bottom of the screen (0, 0 is bottom left). Graphs saved before this
    /// existed lack the key and keep the old top-left origin.
    var yUp = true
    /// Draw nodes take vectors and colours. Older graphs have separate x/y/w/h/r/g/b inputs and are converted on load.
    var vectorDraw = true
    /// Set (to a sprite asset name, "" until one is chosen) when this file is a sprite actor: one instance
    /// per spawn, with this graph's variables per instance. nil for the program's own logic.
    var actorSprite: String?
    /// Labelled rectangles drawn behind the nodes to group them.
    var boxes: [GraphBox] = []
    /// Frames per second the program runs at (the program graph only); nil means 60.
    var fps: Int?

    func node(_ id: String) -> GraphNode? { nodes.first { $0.id == id } }

    /// Connects `from` -> `to`, replacing whatever already fed that input (or, for an exec output,
    /// whatever that output already ran). Returns false if the ports can't be joined.
    mutating func connect(_ e: GraphEdge) -> Bool {
        guard let a = node(e.fromNode), let b = node(e.toNode), a.id != b.id,
              let out = a.kind.outputs.first(where: { $0.name == e.fromPort }),
              let inp = b.kind.inputs.first(where: { $0.name == e.toPort }),
              out.type == inp.type else { return false }
        if out.type != .exec { edges.removeAll { $0.toNode == e.toNode && $0.toPort == e.toPort } }
        if out.type == .exec { edges.removeAll { $0.fromNode == e.fromNode && $0.fromPort == e.fromPort } }
        edges.append(e)
        return true
    }

    mutating func remove(node id: String) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.fromNode == id || $0.toNode == id }
    }

    static func sample() -> NodeGraph {
        var g = NodeGraph()
        g.variables = [GraphVariable(name: "count", type: .number, initial: "0")]
        let click = GraphNode.make(.onButton, x: 40, y: 40), set = GraphNode.make(.setNumberVar, x: 290, y: 40)
        let get = GraphNode.make(.getNumberVar, x: 40, y: 230), add = GraphNode.make(.add, x: 290, y: 230)
        let toText = GraphNode.make(.numberToText, x: 540, y: 230), join = GraphNode.make(.join, x: 790, y: 230)
        let show = GraphNode.make(.setText, x: 790, y: 40)
        var click2 = click; click2.params["widget"] = "go"
        var set2 = set; set2.params["variable"] = "count"
        var get2 = get; get2.params["variable"] = "count"
        var add2 = add; add2.params["b"] = "1"
        var join2 = join; join2.params["a"] = "Pressed "
        var show2 = show; show2.params["widget"] = "status"
        g.nodes = [click2, set2, get2, add2, toText, join2, show2]
        _ = g.connect(GraphEdge(fromNode: click2.id, fromPort: "then", toNode: set2.id, toPort: "in"))
        _ = g.connect(GraphEdge(fromNode: get2.id, fromPort: "value", toNode: add2.id, toPort: "a"))
        _ = g.connect(GraphEdge(fromNode: add2.id, fromPort: "value", toNode: set2.id, toPort: "value"))
        _ = g.connect(GraphEdge(fromNode: set2.id, fromPort: "then", toNode: show2.id, toPort: "in"))
        _ = g.connect(GraphEdge(fromNode: get2.id, fromPort: "value", toNode: toText.id, toPort: "number"))
        _ = g.connect(GraphEdge(fromNode: toText.id, fromPort: "text", toNode: join2.id, toPort: "b"))
        _ = g.connect(GraphEdge(fromNode: join2.id, fromPort: "text", toNode: show2.id, toPort: "text"))
        return g
    }

    /// Replaces the old x/y/w/h/r/g/b inputs of Draw nodes with Make Vector / Colour nodes feeding the new ones.
    mutating func migrateDrawNodes() {
        vectorDraw = true
        var added: [GraphNode] = []
        func rewire(_ node: String, _ ports: [String: String], to helper: String) {
            for i in edges.indices where edges[i].toNode == node {
                if let np = ports[edges[i].toPort] { edges[i].toNode = helper; edges[i].toPort = np }
            }
        }
        func helper(_ kind: NodeKind, for n: GraphNode, dx: Double, dy: Double, params: [String: String], ports: [String: String], into port: String) {
            var h = GraphNode.make(kind, x: n.x - dx, y: n.y + dy)
            for (k, v) in params { h.params[k] = v }
            rewire(n.id, ports, to: h.id)
            edges.append(GraphEdge(fromNode: h.id, fromPort: kind == .makeColour ? "colour" : "vector", toNode: n.id, toPort: port))
            added.append(h)
        }
        for n in nodes where [.drawRect, .drawText, .drawSprite, .setColor].contains(n.kind) {
            let p = n.params
            if n.kind != .setColor {
                helper(.makeVector, for: n, dx: 260, dy: 0, params: ["x": p["x"] ?? "0", "y": p["y"] ?? "0"], ports: ["x": "x", "y": "y"], into: "position")
            }
            if n.kind == .drawRect {
                helper(.makeVector, for: n, dx: 260, dy: 110, params: ["x": p["w"] ?? "32", "y": p["h"] ?? "32"], ports: ["w": "x", "h": "y"], into: "size")
            }
            if n.kind != .drawSprite {
                helper(.makeColour, for: n, dx: 260, dy: 220, params: ["r": p["r"] ?? "255", "g": p["g"] ?? "255", "b": p["b"] ?? "255"], ports: ["r": "r", "g": "g", "b": "b"], into: "colour")
            }
            if let i = nodes.firstIndex(where: { $0.id == n.id }) {
                for k in ["x", "y", "w", "h", "r", "g", "b"] { nodes[i].params[k] = nil }
                if n.kind == .drawRect {
                    nodes[i].params["alpha"] = p["a"] ?? "255"; nodes[i].params["a"] = nil
                    nodes[i].params["size"] = nil; nodes[i].params["colour"] = nil
                }
            }
            for i in edges.indices where edges[i].toNode == n.id && edges[i].toPort == "a" { edges[i].toPort = "alpha" }
        }
        nodes += added
    }

    static func parse(_ data: Data) throws -> NodeGraph {
        var g = try JSONDecoder().decode(NodeGraph.self, from: data)
        // Branch's "done" output was renamed "regardless".
        let branches = Set(g.nodes.filter { $0.kind == .branch }.map(\.id))
        for i in g.edges.indices where g.edges[i].fromPort == "done" && branches.contains(g.edges[i].fromNode) { g.edges[i].fromPort = "regardless" }
        if !g.vectorDraw { g.migrateDrawNodes() }
        return g
    }

    func serialize() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }
}

nonisolated extension NodeGraph {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([GraphNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([GraphEdge].self, forKey: .edges) ?? []
        variables = try c.decodeIfPresent([GraphVariable].self, forKey: .variables) ?? []
        yUp = try c.decodeIfPresent(Bool.self, forKey: .yUp) ?? false
        vectorDraw = try c.decodeIfPresent(Bool.self, forKey: .vectorDraw) ?? false
        actorSprite = try c.decodeIfPresent(String.self, forKey: .actorSprite)
        boxes = try c.decodeIfPresent([GraphBox].self, forKey: .boxes) ?? []
        fps = try c.decodeIfPresent(Int.self, forKey: .fps)
    }
}
