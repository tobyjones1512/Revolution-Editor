import Foundation

/// A resolved Swift type. Tuple labels don't take part in equality, as in Swift.
nonisolated indirect enum SType: Hashable {
    case int, uint32, uint8, double, float, bool, string, void
    case named(String)                       // struct, class or enum
    case array(SType)
    case dict(SType, SType)
    case optional(SType)
    case tuple([SType], [String?])
    case fn([SType], SType)
    case binding(SType)                      // @Binding / $state: a pointer to the value
    case view                                // some View, only inside a view builder

    static func == (a: SType, b: SType) -> Bool {
        switch (a, b) {
        case (.int, .int), (.uint32, .uint32), (.uint8, .uint8), (.double, .double), (.float, .float), (.bool, .bool),
             (.string, .string), (.void, .void), (.view, .view): return true
        case (.named(let x), .named(let y)): return x == y
        case (.dict(let k1, let v1), .dict(let k2, let v2)): return k1 == k2 && v1 == v2
        case (.array(let x), .array(let y)), (.optional(let x), .optional(let y)), (.binding(let x), .binding(let y)): return x == y
        case (.tuple(let x, _), .tuple(let y, _)): return x == y
        case (.fn(let ap, let ar), .fn(let bp, let br)): return ap == bp && ar == br
        default: return false
        }
    }

    func hash(into h: inout Hasher) { h.combine(mangled) }

    var isInteger: Bool { self == .int || self == .uint32 || self == .uint8 }
    var isFloating: Bool { self == .double || self == .float }
    var isNumeric: Bool { isInteger || isFloating }

    /// How the type reads in error messages.
    var name: String {
        switch self {
        case .int: return "Int"
        case .uint32: return "UInt32"
        case .uint8: return "UInt8"
        case .double: return "Double"
        case .float: return "Float"
        case .bool: return "Bool"
        case .string: return "String"
        case .void: return "Void"
        case .named(let n): return n
        case .array(let e): return "[\(e.name)]"
        case .dict(let k, let v): return "[\(k.name): \(v.name)]"
        case .optional(let e): return "\(e.name)?"
        case .tuple(let es, _): return "(" + es.map(\.name).joined(separator: ", ") + ")"
        case .fn(let ps, let r): return "(" + ps.map(\.name).joined(separator: ", ") + ") -> " + r.name
        case .binding(let e): return "Binding<\(e.name)>"
        case .view: return "some View"
        }
    }

    /// A C-identifier-safe form, used to name generated types.
    var mangled: String {
        switch self {
        case .int: return "int"
        case .uint32: return "u32"
        case .uint8: return "u8"
        case .double: return "dbl"
        case .float: return "flt"
        case .bool: return "bool"
        case .string: return "str"
        case .void: return "void"
        case .named(let n): return n
        case .array(let e): return "A_" + e.mangled
        case .dict(let k, let v): return "D_" + k.mangled + "_" + v.mangled
        case .optional(let e): return "O_" + e.mangled
        case .tuple(let es, _): return "P" + es.map(\.mangled).joined(separator: "_") + "_"
        case .fn(let ps, let r): return "F" + ps.map(\.mangled).joined(separator: "_") + "_R" + r.mangled
        case .binding(let e): return "B_" + e.mangled
        case .view: return "view"
        }
    }
}

nonisolated struct ParamInfo {
    var label: String?
    var name: String
    var type: SType
    var defaultValue: Expr?
    var isInout: Bool
}

nonisolated struct FuncInfo {
    var decl: FuncDecl
    var owner: String?
    var params: [ParamInfo]
    var ret: SType
    var cName: String
    var isStatic: Bool
    /// For a specialised generic function: what its type parameters stand for.
    var bindings: [String: SType] = [:]
}

nonisolated struct PropInfo {
    var decl: PropDecl
    var type: SType
    var isBinding: Bool { decl.attrs.contains("Binding") }
    var isState: Bool { decl.attrs.contains("State") || decl.attrs.contains("StateObject") }
    var isComputed: Bool { decl.getter != nil }
    var name: String { decl.name }
}

nonisolated final class TypeInfo {
    enum Kind { case structType, classType, enumType, protocolType }
    var name: String
    var kind: Kind
    var decl: TypeDecl
    var props: [PropInfo] = []
    var methods: [String: FuncInfo] = [:]
    var inits: [FuncInfo] = []
    var cases: [String] = []
    var rawType: SType?
    var rawValues: [String: Expr] = [:]
    var casePayloads: [String: [(label: String?, type: SType)]] = [:]
    var hasPayload: Bool { casePayloads.values.contains { !$0.isEmpty } }
    var isProtocol: Bool { kind == .protocolType }
    var conformances: [String]
    /// For a specialisation of a generic type (`Stack<Int>`): what its parameters stand for.
    var bindings: [String: SType] = [:]
    var origin: (template: String, args: [SType])?
    var isView: Bool { conformances.contains("View") }
    var isApp: Bool { conformances.contains("App") }
    var isClass: Bool { kind == .classType }

    init(decl: TypeDecl) {
        self.decl = decl
        name = decl.name
        conformances = decl.conformances
        switch decl.kind {
        case .structType: kind = .structType
        case .classType: kind = .classType
        case .enumType: kind = .enumType
        case .protocolType: kind = .protocolType
        }
    }

    var storedProps: [PropInfo] { props.filter { !$0.decl.isStatic && !$0.isComputed } }
}
