import Foundation

/// The syntax tree for the Swift subset Revolution Editor translates to C (see `SwiftParser` and
/// `SwiftTranslator`).
nonisolated struct SwiftError: Error, LocalizedError {
    var file: String
    var line: Int
    var col: Int
    var message: String
    var errorDescription: String? { "\(file):\(line):\(col): error: \(message)" }
}

nonisolated indirect enum TypeExpr {
    case name(String, [TypeExpr])           // Int, Binding<Bool>, ...
    case array(TypeExpr)
    case dict(TypeExpr, TypeExpr)
    case optional(TypeExpr)
    case tuple([(label: String?, type: TypeExpr)])
    case function([TypeExpr], TypeExpr)
    case some(TypeExpr)                     // some View
}

nonisolated struct Arg {
    var label: String?
    var value: Expr
}

nonisolated struct Closure {
    var params: [(name: String, type: TypeExpr?)]
    var ret: TypeExpr?
    var body: [Stmt]
    var hasSignature: Bool
    var maxShorthand: Int                   // highest $n used (1 for $0), 0 if none
}

nonisolated struct StrInterp { var text: String?; var expr: Expr? }

nonisolated struct Expr {
    indirect enum Kind {
        case int(Int), double(Double), bool(Bool), string([StrInterp]), nilLit
        case ident(String), selfRef, shorthand(Int), binding(String)      // $0, $name
        case member(Expr, String, optional: Bool)
        case implicitMember(String)
        case tupleIndex(Expr, Int)
        case call(Expr, [Arg])
        case subscripted(Expr, Expr)
        case dictSubscriptDefault(Expr, Expr, Expr)   // dict[key, default: value]
        case unary(String, Expr)
        case binary(String, Expr, Expr)
        case ternary(Expr, Expr, Expr)
        case range(Expr, Expr, inclusive: Bool)
        case arrayLiteral([Expr])
        case dictLiteral([(key: Expr, value: Expr)])
        case letPattern(String)             // `let r` inside an enum case pattern
        case tupleLit([(label: String?, value: Expr)])
        case forceUnwrap(Expr)
        case closure(Closure)
        case inoutRef(Expr)
        case typeRef(TypeExpr)              // [Int] in [Int](repeating: 0, count: 3)
        case genericRef(String, [TypeExpr])  // Stack<Int> in Stack<Int>()
        case keyPath(String)                // \.self, \.name (only accepted where identity is ignored)
        case opRef(String)                  // + in reduce(0, +)
    }
    var kind: Kind
    var line: Int
    var col: Int
}

nonisolated indirect enum Pattern {
    case name(String)
    case wildcard
    case tuple([Pattern])
}

nonisolated enum Condition {
    case bool(Expr)
    case bind(Pattern, Expr, isVar: Bool)   // if let x = e
    case match(Expr, Expr)                  // if case .circle(let r) = shape
}

nonisolated struct Stmt {
    indirect enum Kind {
        case decl(Pattern, TypeExpr?, Expr?, isLet: Bool)
        case assign(op: String, lhs: Expr, rhs: Expr)
        case expr(Expr)
        case ifElse([Condition], then: [Stmt], else: [Stmt]?)
        case guardElse([Condition], else: [Stmt])
        case whileLoop([Condition], body: [Stmt])
        case repeatWhile(body: [Stmt], cond: Expr)
        case forIn(Pattern, Expr, body: [Stmt])
        case switchOn(Expr, cases: [(patterns: [Expr], body: [Stmt])], default: [Stmt]?)
        case ret(Expr?)
        case brk, cont
        case localFunc(FuncDecl)
    }
    var kind: Kind
    var line: Int
    var col: Int
}

nonisolated struct Param {
    var label: String?
    var name: String
    var type: TypeExpr
    var defaultValue: Expr?
    var isInout: Bool
}

nonisolated struct FuncDecl {
    var name: String
    var params: [Param]
    var ret: TypeExpr?
    var body: [Stmt]
    var isMutating = false
    var isStatic = false
    var isRequirement = false              // a protocol requirement: no body
    var generics: [String] = []
    var line: Int
    var col: Int
    var file: String
}

nonisolated struct PropDecl {
    var name: String
    var type: TypeExpr?
    var value: Expr?
    var isLet: Bool
    var isStatic: Bool
    var attrs: Set<String>                  // State, Binding, StateObject, ObservedObject, Published, ...
    var getter: [Stmt]?                     // computed property
    var setter: (param: String, body: [Stmt])?
    var line: Int
    var col: Int
}

nonisolated struct TypeDecl {
    enum Kind { case structType, classType, enumType, protocolType }
    var kind: Kind
    var name: String
    var conformances: [String]
    var props: [PropDecl] = []
    var methods: [FuncDecl] = []
    var inits: [FuncDecl] = []
    var cases: [(name: String, raw: Expr?, payload: [(label: String?, type: TypeExpr)])] = []
    var rawType: TypeExpr?
    var isMain = false
    var generics: [String] = []
    var line: Int
    var file: String
}

nonisolated struct ExtensionDecl {
    var typeName: String
    var conformances: [String]
    var props: [PropDecl]
    var methods: [FuncDecl]
    var inits: [FuncDecl]
    var line: Int
    var file: String
}

nonisolated struct GlobalDecl { var stmt: Stmt; var file: String }

nonisolated struct SwiftProgram {
    var funcs: [FuncDecl] = []
    var types: [TypeDecl] = []
    var extensions: [ExtensionDecl] = []
    var aliases: [(name: String, type: TypeExpr, file: String, line: Int)] = []
    var globals: [GlobalDecl] = []
}
