import Foundation

/// Type-checks a `SwiftProgram` and emits C for devkitPPC. Value semantics are kept (strings,
/// arrays, optionals, tuples and structs are C values; classes are heap objects that are never
/// freed). Everything user-visible is prefixed (`sw_`, `T_`, `C_`) so it can't collide with libogc.
nonisolated struct Local {
    var type: SType
    var c: String
    var isLet: Bool
    var captured = false
}

nonisolated final class FnCtx {
    var scopes: [[String: Local]] = [[:]]
    var ret: SType = .void
    var selfType: TypeInfo?
    var isMutating = false
    var isInit = false
    var isStatic = false
    /// While an inlined closure body is being translated: where `return` goes.
    var closures: [ClosureFrame] = []
    /// Nested functions declared in this function (they're lifted to the top level).
    var localFuncs: [String: FuncInfo] = [:]
    /// For a lifted closure: the function it was written in, and what it has captured from it.
    var captureParent: FnCtx?
    var captured: [String: Local] = [:]
    var usedSelf = false
    /// A closure passed straight to a function (assumed not to outlive the call) sees the real
    /// variables; one that may be kept (a SwiftUI action, a stored closure) gets copies.
    var captureByReference = false
    /// Statements are views being added to the tree (a view's body, a container's content).
    var viewMode = false
}

nonisolated final class ClosureFrame {
    var resultVar: String?
    var label: String
    var ret: SType
    init(resultVar: String?, label: String, ret: SType) { self.resultVar = resultVar; self.label = label; self.ret = ret }
}

nonisolated final class SwiftTranslator {
    struct Output {
        var source: String
        /// C hook functions the Swift code defines (`app_on_frame`, ...).
        var hooks: Set<String>
        /// Whether the code builds SwiftUI views (so wui.h/wui.c are needed).
        var usesWui = false
    }

    static let hookNames: [String: (c: String, params: [SType])] = [
        "appOnStart": ("app_on_start", []), "appOnFrame": ("app_on_frame", []), "appOnDraw": ("app_on_draw", []),
        "appOnButton": ("app_on_button", [.int]), "appOnWpad": ("app_on_wpad", [.uint32]),
    ]

    static let cReserved: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto",
        "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch",
        "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true", "false", "NULL", "TRUE", "FALSE", "main", "exit",
        "u8", "u16", "u32", "u64", "s8", "s16", "s32", "s64", "f32", "f64", "self_", "id", "pressed", "index", "time", "abs", "min", "max",
        "round", "floor", "ceil", "sqrt", "sin", "cos", "tan", "pow", "log", "exp", "free", "malloc", "calloc", "printf", "rand", "srand",
    ]

    // Program
    let prog: SwiftProgram
    let widgets: Set<String>
    let sprites: Set<String>
    let sounds: Set<String>
    let musics: Set<String>
    let testing: Bool

    // Declarations
    var types: [String: TypeInfo] = [:]
    var typeOrder: [String] = []
    var aliases: [String: TypeExpr] = [:]
    var funcs: [String: FuncInfo] = [:]
    var globals: [String: Local] = [:]
    var constInts: [String: Int] = [:]

    // Generated text
    var typeDefs: [String] = []
    var registered: Set<String> = []
    var inProgress: Set<String> = []
    var classForwards: [String] = []
    var classBodies: [String] = []
    var protos: [String] = []
    var bodies: [String] = []
    var globalDecls: [String] = []
    var initLines: [String] = []
    var statics: [String] = []
    var usesView = false
    /// For each protocol: the concrete types that conform to it (directly or through a parent protocol).
    var protocolConformers: [String: [String]] = [:]
    /// Generic functions and types, specialised when used.
    var genericFuncs: [String: FuncDecl] = [:]
    var genericTypes: [String: TypeDecl] = [:]
    var bindingStack: [[String: SType]] = []
    var finishedTypes: Set<String> = []
    var bodiedTypes: Set<String> = []
    lazy var builtinFunctions: [String: Builtin] = SwiftTranslator.makeBuiltins()

    // Context
    var ctx = FnCtx()
    var curFile = ""
    var curLine = 0
    var curCol = 0
    var tmp = 0

    init(prog: SwiftProgram, widgets: [String], sprites: [String], sounds: [String], musics: [String] = [], testing: Bool = false) {
        self.prog = prog
        self.widgets = Set(widgets)
        self.sprites = Set(sprites)
        self.sounds = Set(sounds)
        self.musics = Set(musics)
        self.testing = testing
    }

    // MARK: Errors and helpers

    func fail(_ m: String) -> SwiftError { SwiftError(file: curFile, line: curLine, col: curCol, message: m) }
    func at(_ e: Expr) { curLine = e.line; curCol = e.col }
    func at(_ s: Stmt) { curLine = s.line; curCol = s.col }
    func newTmp(_ p: String) -> String { tmp += 1; return "_\(p)\(tmp)" }
    func cname(_ n: String) -> String {
        if n.hasPrefix("$") { return "_sh" + n.dropFirst() }
        return Self.cReserved.contains(n) ? n + "_" : n
    }
    func ind(_ n: Int) -> String { String(repeating: "    ", count: n) }

    // MARK: Type resolution

    func resolve(_ t: TypeExpr) throws -> SType {
        switch t {
        case .array(let e): return .array(try resolve(e))
        case .dict(let k, let v):
            let kt = try resolve(k)
            guard kt == .string || kt.isInteger || kt == .bool || isEnum(kt) else { throw fail("dictionary keys must be String, Int, Bool or an enum, not \(kt.name)") }
            return .dict(kt, try resolve(v))
        case .optional(let e): return .optional(try resolve(e))
        case .tuple(let items):
            if items.isEmpty { return .void }
            return .tuple(try items.map { try resolve($0.type) }, items.map { $0.label })
        case .function(let ps, let r): return .fn(try ps.map(resolve), try resolve(r))
        case .some(let inner):
            if case .name("View", _) = inner { usesView = true; return .view }
            throw fail("'some \(typeExprName(inner))' isn't supported")
        case .name(let n, let args):
            switch n {
            case "Int", "Int32", "Int16", "Int64": return .int
            case "UInt32", "UInt", "UInt16": return .uint32
            case "UInt8": return .uint8
            case "Double", "CGFloat": return .double
            case "Float": return .float
            case "Bool": return .bool
            case "String", "Character": return .string
            case "Void": return .void
            case "Binding":
                guard args.count == 1 else { throw fail("Binding needs one type, like Binding<Bool>") }
                return .binding(try resolve(args[0]))
            default: break
            }
            if args.isEmpty { for b in bindingStack.reversed() { if let t = b[n] { return t } } }
            if let a = aliases[n] { return try resolve(a) }
            if let tn = n.split(separator: ".").last.map(String.init), types[n] == nil, types[tn] != nil { return .named(tn) }
            if types[n] != nil {
                if !args.isEmpty { throw fail("'\(n)' doesn't take type arguments") }
                return .named(n)
            }
            if let d = genericTypes[n] {
                guard args.count == d.generics.count else { throw fail("'\(n)' needs \(d.generics.count) type argument\(d.generics.count == 1 ? "" : "s"), like \(n)<\(d.generics.joined(separator: ", "))>") }
                return try instantiateType(d, try args.map(resolve))
            }
            throw fail("cannot find type '\(n)' in scope")
        }
    }

    func typeExprName(_ t: TypeExpr) -> String {
        switch t {
        case .name(let n, _): return n
        case .array(let e): return "[\(typeExprName(e))]"
        case .dict(let k, let v): return "[\(typeExprName(k)): \(typeExprName(v))]"
        case .optional(let e): return typeExprName(e) + "?"
        case .tuple: return "tuple"
        case .function: return "function"
        case .some(let e): return "some " + typeExprName(e)
        }
    }

    func info(_ t: SType) -> TypeInfo? { if case .named(let n) = t { return types[n] }; return nil }
    func isClass(_ t: SType) -> Bool { info(t)?.isClass ?? false }
    func isEnum(_ t: SType) -> Bool { info(t)?.kind == .enumType }

    // MARK: C types

    /// The C type for `t`, registering any generated typedefs it needs.
    func ctype(_ t: SType) throws -> String {
        switch t {
        case .int, .bool: return "int"
        case .uint32: return "unsigned int"
        case .uint8: return "unsigned char"
        case .double: return "double"
        case .float: return "float"
        case .string: return "wn_str"
        case .void: return "void"
        case .view: return "void"
        case .binding(let e): return try ctype(e) + " *"
        case .named(let n):
            guard let ti = types[n] else { throw fail("unknown type '\(n)'") }
            switch ti.kind {
            case .classType: return "C_\(n) *"
            case .enumType, .structType: try register(t); return "T_\(n)"
            case .protocolType: try register(t); return "X_\(n)"
            }
        case .array, .optional, .tuple, .dict:
            try register(t)
            return t.mangled
        case .fn(let ps, let r):
            try register(t)
            _ = (ps, r)
            return t.mangled
        }
    }

    func decl(_ t: SType, _ name: String) throws -> String {
        let c = try ctype(t)
        return c.hasSuffix("*") ? "\(c)\(name)" : "\(c) \(name)"
    }

    func capacity(_ e: SType) -> Int {
        switch e {
        case .int, .uint32, .uint8, .double, .float, .bool: return 256
        case .named(let n): return types[n]?.kind == .structType ? 64 : 128
        case .string: return 32
        case .array: return 8
        default: return 32
        }
    }

    func dictCapacity(_ v: SType) -> Int {
        switch v {
        case .string: return 32
        case .array: return 8
        case .named(let n): return types[n]?.kind == .structType ? 24 : 64
        case .tuple, .dict, .optional: return 16
        default: return 64
        }
    }

    /// Emits the typedef (and helpers) for a generated or user value type, once.
    func register(_ t: SType) throws {
        let key = t.mangled
        if registered.contains(key) { return }
        if inProgress.contains(key) { throw fail("'\(t.name)' contains itself; use a class for recursive data") }
        inProgress.insert(key)
        defer { inProgress.remove(key) }
        var text = ""
        switch t {
        case .array(let e):
            let ec = try ctype(e), cap = capacity(e), m = key
            let isRef = ec.hasSuffix("*")
            let elem = isRef ? ec : ec
            text = """
            typedef struct { \(elem) a[\(cap)]; int n; } \(m);
            static __attribute__((unused)) void \(m)_append(\(m) *s, \(elem) v) { if (s->n >= \(cap)) ws_fatal(); s->a[s->n++] = v; }
            static __attribute__((unused)) void \(m)_insert(\(m) *s, int i, \(elem) v) { if (s->n >= \(cap) || i < 0 || i > s->n) ws_fatal(); for (int k = s->n; k > i; k--) s->a[k] = s->a[k - 1]; s->a[i] = v; s->n++; }
            static __attribute__((unused)) \(elem) \(m)_removeAt(\(m) *s, int i) { if (i < 0 || i >= s->n) ws_fatal(); \(elem) v = s->a[i]; for (int k = i; k < s->n - 1; k++) s->a[k] = s->a[k + 1]; s->n--; return v; }
            """
        case .dict(let k, let v):
            let kc = try ctype(k), vc = try ctype(v), cap = dictCapacity(v), m = key
            let eq = k == .string ? "ws_eq(s->k[i], key)" : "s->k[i] == key"
            text = """
            typedef struct { \(kc) k[\(cap)]; \(vc) v[\(cap)]; int n; } \(m);
            static __attribute__((unused)) int \(m)_find(const \(m) *s, \(kc) key) { for (int i = 0; i < s->n; i++) if (\(eq)) return i; return -1; }
            static __attribute__((unused)) void \(m)_set(\(m) *s, \(kc) key, \(vc) val) { int i = \(m)_find(s, key); if (i < 0) { if (s->n >= \(cap)) ws_fatal(); i = s->n++; s->k[i] = key; } s->v[i] = val; }
            static __attribute__((unused)) void \(m)_remove(\(m) *s, \(kc) key) { int i = \(m)_find(s, key); if (i < 0) return; for (int j = i; j < s->n - 1; j++) { s->k[j] = s->k[j + 1]; s->v[j] = s->v[j + 1]; } s->n--; }
            """
        case .optional(let e):
            let ec = try ctype(e)
            text = "typedef struct { int has; \(ec) v; } \(key);"
        case .tuple(let es, _):
            var fields = ""
            for (i, e) in es.enumerated() { fields += "\(try decl(e, "f\(i)")); " }
            text = "typedef struct { \(fields)} \(key);"
        case .fn(let ps, let r):
            var params = ["void *ctx"]
            for p in ps { params.append(try ctype(p)) }
            text = "typedef struct { \(try ctype(r)) (*f)(\(params.joined(separator: ", "))); void *ctx; } \(key);"
        case .named(let n):
            guard let ti = types[n] else { throw fail("unknown type '\(n)'") }
            if ti.kind == .protocolType {
                let conformers = protocolConformers[n] ?? []
                if conformers.isEmpty { throw fail("no type conforms to the protocol '\(n)'") }
                var members = ""
                for (i, c) in conformers.enumerated() { members += "\(try decl(.named(c), "v\(i)")); " }
                text = "typedef struct { int tag; union { \(members)} u; } X_\(n);"
                registered.insert(key)
                typeDefs.append(text)
                return
            }
            if ti.kind == .enumType, ti.hasPayload {
                var unions = ""
                for c in ti.cases {
                    let pl = ti.casePayloads[c] ?? []
                    if pl.isEmpty { continue }
                    var fields = ""
                    for (i, p) in pl.enumerated() { fields += "\(try decl(p.type, "f\(i)")); " }
                    unions += "struct { \(fields)} c_\(c); "
                }
                text = "typedef enum { " + ti.cases.map { "T_\(n)_\($0)" }.joined(separator: ", ") + " } T_\(n)_tag;\n"
                text += "typedef struct { T_\(n)_tag tag; union { \(unions.isEmpty ? "char _unused; " : unions)} u; } T_\(n);"
            } else if ti.kind == .enumType {
                text = "typedef enum { " + ti.cases.map { "T_\(n)_\($0)" }.joined(separator: ", ") + " } T_\(n);"
            } else {
                var fields = ""
                for p in ti.storedProps {
                    fields += "\(try decl(p.isBinding ? .binding(p.type) : p.type, cname(p.name))); "
                }
                if fields.isEmpty { fields = "char _unused; " }
                text = "typedef struct { \(fields)} T_\(n);"
            }
        default: return
        }
        registered.insert(key)
        typeDefs.append(text)
    }

    // MARK: Program assembly

    func run() throws -> Output {
        try collectDeclarations()
        try finishNewTypes()

        // Prototypes first, so everything can call everything.
        for f in funcs.values.sorted(by: { $0.cName < $1.cName }) { try emitPrototype(f) }
        try declareGlobals()

        // Bodies. Translating one can specialise generics, which adds more to do.
        var doneFuncs = Set<String>()
        var progress = true
        while progress {
            progress = false
            for f in funcs.values.sorted(by: { $0.cName < $1.cName }) where doneFuncs.insert(f.cName).inserted {
                bodies.append(try function(f))
                progress = true
                try finishNewTypes()
            }
            for n in typeOrder where !bodiedTypes.contains(n) {
                bodiedTypes.insert(n)
                let ti = types[n]!
                if ti.isProtocol { continue }
                try withBindings(ti.bindings) {
                    for f in ti.methods.values.sorted(by: { $0.cName < $1.cName }) { bodies.append(try function(f)) }
                    for f in ti.inits { bodies.append(try initializer(ti, f)) }
                    if ti.kind == .classType, ti.inits.isEmpty { bodies.append(try defaultClassInit(ti)) }
                    for p in ti.props where p.isComputed { bodies.append(contentsOf: try accessors(ti, p)) }
                }
                progress = true
                try finishNewTypes()
            }
        }

        let hooks = try emitHooks()
        try finishNewTypes()
        return Output(source: assemble(hooks.text), hooks: hooks.names, usesWui: hooks.wui)
    }

    var emittedPrototypes: Set<String> {
        get { registered }
        set { registered = newValue }
    }

    func emitPrototype(_ f: FuncInfo) throws {
        let key = "proto." + f.cName
        if registered.contains(key) { return }
        registered.insert(key)
        protos.append(try prototype(f) + ";")
    }

    /// Lays out and declares every type that doesn't have its C representation yet.
    func finishNewTypes() throws {
        while let n = typeOrder.first(where: { !finishedTypes.contains($0) }) {
            finishedTypes.insert(n)
            let ti = types[n]!
            if ti.isProtocol { continue }
            curFile = ti.decl.file; curLine = ti.decl.line; curCol = 1
            try withBindings(ti.bindings) {
                if ti.isClass {
                    for p in ti.storedProps { _ = try ctype(p.isBinding ? .binding(p.type) : p.type) }
                    classForwards.append("typedef struct C_\(n) C_\(n);")
                    var fields = ""
                    for p in ti.storedProps { fields += "    \(try decl(p.isBinding ? .binding(p.type) : p.type, cname(p.name)));\n" }
                    if fields.isEmpty { fields = "    char _unused;\n" }
                    classBodies.append("struct C_\(n) {\n\(fields)};")
                } else {
                    try register(.named(n))
                }
                for f in ti.methods.values.sorted(by: { $0.cName < $1.cName }) { try emitPrototype(f) }
                for f in ti.inits { try emitPrototype(f) }
                if ti.kind == .classType, ti.inits.isEmpty { protos.append("static __attribute__((unused)) C_\(n) *C_\(n)_new(void);") }
                for p in ti.props where p.isComputed {
                    protos.append(try accessorPrototype(ti, p, setter: false) + ";")
                    if p.decl.setter != nil { protos.append(try accessorPrototype(ti, p, setter: true) + ";") }
                }
                try declareStatics(for: ti)
            }
        }
    }

    func assemble(_ hookText: String) -> String {
        var out = "/* swift_generated.c, translated from Swift by Revolution Editor. Do not edit. */\n"
        out += "#include <math.h>\n#include \"ui_generated.h\"\n#include \"ws.h\"\n"
        if usesView { out += "#include \"wui.h\"\n" }
        out += "\n"
        if testing { out += "extern void host_check(int ok, const char *name);\nextern void host_value(const char *name, int value);\n\n" }
        out += classForwards.joined(separator: "\n") + "\n"
        out += typeDefs.joined(separator: "\n") + "\n"
        out += classBodies.joined(separator: "\n") + "\n\n"
        out += protos.joined(separator: "\n") + "\n\n"
        out += globalDecls.joined(separator: "\n") + "\n\n"
        out += statics.joined(separator: "\n") + "\n\n"
        out += "static __attribute__((unused)) void sw_init_globals(void) {\n" + initLines.map { "    " + $0.replacingOccurrences(of: "\n", with: "\n    ") + "\n" }.joined() + "}\n"
        out += "__attribute__((constructor)) static void sw_boot(void) { sw_init_globals(); }\n\n"
        out += bodies.joined(separator: "\n")
        out += "\n" + hookText
        return out
    }

    func emitHooks() throws -> (text: String, names: Set<String>, wui: Bool) {
        var text = "", names = Set<String>(), wui = false
        if let root = try findRootView() {
            if funcs["appOnDraw"] != nil { curFile = funcs["appOnDraw"]!.decl.file; curLine = funcs["appOnDraw"]!.decl.line; throw fail("a SwiftUI app draws itself; remove appOnDraw (or remove the SwiftUI views)") }
            ctx = FnCtx()
            curFile = root.type.decl.file; curLine = root.type.decl.line
            let (initC, _) = try expr(root.initExpr, nil)
            globalDecls.append("static __attribute__((unused)) T_\(root.type.name) sw_root;")
            initLines.append("sw_root = \(initC);")
            text += "void app_on_draw(void) { wui_begin(); T_\(root.type.name)_get_body(&sw_root); wui_finish(); }\n"
            names.insert("app_on_draw")
            wui = true
        }
        for (swiftName, info) in Self.hookNames {
            guard let f = funcs[swiftName] else { continue }
            curFile = f.decl.file; curLine = f.decl.line; curCol = f.decl.col
            guard f.params.map(\.type) == info.params, f.ret == .void else {
                throw fail("\(swiftName) must be declared as func \(swiftName)(\(info.params.isEmpty ? "" : "_ " + (swiftName == "appOnButton" ? "id: Int" : "pressed: UInt32"))) with no return value")
            }
            names.insert(info.c)
            let sig = info.params.isEmpty ? "void" : (info.params[0] == .int ? "int a" : "unsigned int a")
            text += "void \(info.c)(\(sig)) { sw_\(swiftName)(\(info.params.isEmpty ? "" : "a")); }\n"
        }
        return (text, names, wui)
    }

    // MARK: Declarations

    func collectDeclarations() throws {
        for a in prog.aliases {
            curFile = a.file; curLine = a.line; curCol = 1
            aliases[a.name] = a.type
        }
        for d in prog.types {
            curFile = d.file; curLine = d.line; curCol = 1
            if types[d.name] != nil || genericTypes[d.name] != nil { throw fail("invalid redeclaration of '\(d.name)'") }
            if !d.generics.isEmpty {
                if d.kind == .protocolType { throw fail("generic protocols aren't supported") }
                genericTypes[d.name] = d
                continue
            }
            types[d.name] = TypeInfo(decl: d)
            typeOrder.append(d.name)
        }
        let knownProtocols: Set<String> = ["View", "App", "Scene", "ObservableObject", "Identifiable", "Hashable", "Equatable", "Comparable", "CaseIterable", "Codable", "Encodable", "Decodable", "Sendable", "CustomStringConvertible", "RawRepresentable"]
        for n in typeOrder {
            let ti = types[n]!
            curFile = ti.decl.file; curLine = ti.decl.line; curCol = 1
            for c in ti.conformances where !knownProtocols.contains(c) {
                guard let other = types[c] else { throw fail("cannot find the protocol '\(c)'" + (ti.isClass ? " (a class can't inherit from another class here)" : "")) }
                if other.kind != .protocolType { throw fail("'\(n)' can't inherit from '\(c)': inheritance isn't supported") }
            }
        }
        for e in prog.extensions {
            curFile = e.file; curLine = e.line; curCol = 1
            if var g = genericTypes[e.typeName] {
                g.props += e.props; g.methods += e.methods; g.inits += e.inits; g.conformances += e.conformances
                genericTypes[e.typeName] = g
                continue
            }
            guard let ti = types[e.typeName] else { throw fail("cannot extend '\(e.typeName)': only your own types can be extended") }
            if ti.isProtocol { throw fail("protocol extensions aren't supported; put the code in each type") }
            ti.decl.props += e.props
            ti.decl.methods += e.methods
            ti.decl.inits += e.inits
            ti.conformances += e.conformances
        }
        // Signatures first (so a property's initial value can call a type's init), then properties.
        for n in typeOrder { try collectSignatures(types[n]!) }
        for n in typeOrder { try collectProps(types[n]!) }
        try computeConformers()
        for f in prog.funcs {
            curFile = f.file; curLine = f.line; curCol = f.col
            if funcs[f.name] != nil || genericFuncs[f.name] != nil { throw fail("invalid redeclaration of '\(f.name)' (overloading isn't supported)") }
            if !f.generics.isEmpty { genericFuncs[f.name] = f; continue }
            funcs[f.name] = try funcInfo(f, owner: nil)
        }
    }

    /// Enum cases, method and initialiser signatures of `ti`.
    func collectSignatures(_ ti: TypeInfo) throws {
        curFile = ti.decl.file; curLine = ti.decl.line; curCol = 1
        if ti.kind == .enumType {
            ti.cases = ti.decl.cases.map(\.name)
            if let r = ti.decl.rawType { ti.rawType = try resolve(r) }
            for c in ti.decl.cases { if let raw = c.raw { ti.rawValues[c.name] = raw } }
            if ti.cases.isEmpty { throw fail("an enum needs at least one case") }
            for c in ti.decl.cases where !c.payload.isEmpty { ti.casePayloads[c.name] = try c.payload.map { (label: $0.label, type: try resolve($0.type)) } }
            if ti.hasPayload, ti.rawType != nil { throw fail("an enum with values can't also have a raw type") }
        }
        for m in ti.decl.methods {
            curFile = m.file; curLine = m.line; curCol = m.col
            if !m.generics.isEmpty { throw fail("generic methods aren't supported; make the function generic instead") }
            if ti.methods[m.name] != nil { throw fail("invalid redeclaration of '\(m.name)' (overloading isn't supported)") }
            ti.methods[m.name] = try funcInfo(m, owner: ti)
        }
        for i in ti.decl.inits { ti.inits.append(try funcInfo(i, owner: ti)) }
        if ti.inits.count > 1 { throw fail("a type can have only one init (overloading isn't supported)") }
    }

    /// Property types of `ti` (inferred from initial values where not written).
    func collectProps(_ ti: TypeInfo) throws {
        curFile = ti.decl.file; curLine = ti.decl.line; curCol = 1
        if ti.isView || ti.isApp { usesView = true }
        for pd in ti.decl.props {
            if ti.isApp && pd.name == "body" { continue }       // WindowGroup { ... } is read by findRootView
            curLine = pd.line; curCol = pd.col
            var type: SType
            if let t = pd.type { type = try resolve(t) }
            else if let v = pd.value { type = try inferType(v) }
            else { throw fail("a property needs a type") }
            if pd.attrs.contains("Binding") { if case .binding(let inner) = type { type = inner } }
            if ti.props.contains(where: { $0.name == pd.name }) { throw fail("invalid redeclaration of '\(pd.name)'") }
            ti.props.append(PropInfo(decl: pd, type: type))
        }
    }

    // MARK: Generics

    func withBindings<T>(_ b: [String: SType], _ body: () throws -> T) rethrows -> T {
        bindingStack.append(b)
        defer { bindingStack.removeLast() }
        return try body()
    }

    /// `Stack<Int>`: a copy of the generic type with its parameters replaced, made once.
    func instantiateType(_ d: TypeDecl, _ args: [SType]) throws -> SType {
        let key = d.name + "_" + args.map(\.mangled).joined(separator: "_")
        if types[key] != nil { return .named(key) }
        var decl = d
        decl.name = key
        decl.generics = []
        let ti = TypeInfo(decl: decl)
        ti.bindings = Dictionary(uniqueKeysWithValues: zip(d.generics, args))
        ti.origin = (d.name, args)
        for c in ti.conformances where types[c]?.isProtocol == true { throw fail("a generic type can't conform to your own protocol '\(c)' yet") }
        let saved = (curFile, curLine, curCol)
        types[key] = ti
        typeOrder.append(key)
        try withBindings(ti.bindings) {
            try collectSignatures(ti)
            try collectProps(ti)
        }
        (curFile, curLine, curCol) = saved
        return .named(key)
    }

    /// Works out what a generic function's or type's parameters stand for from the arguments.
    func inferGenerics(_ generics: [String], params: [(label: String?, type: TypeExpr, isInout: Bool)], ret: TypeExpr?, args: [Arg], expected: SType?, owner: String?) throws -> [String: SType] {
        let gens = Set(generics)
        var b: [String: SType] = [:]
        var k = 0
        var closures: [(TypeExpr, Expr)] = []
        for p in params {
            guard k < args.count, args[k].label == p.label else { continue }
            let a = args[k].value
            k += 1
            switch a.kind {
            case .closure, .opRef: closures.append((p.type, a)); continue
            case .inoutRef(let inner): try unify(p.type, try expr(inner, nil).1, gens, &b)
            default:
                // A literal can take a type from another argument, so unify what's already known first.
                let known: SType? = { if case .name(let n, _) = p.type, gens.contains(n) { return b[n] }; return nil }()
                try unify(p.type, try expr(a, known).1, gens, &b)
            }
        }
        for (te, arg) in closures {
            guard case .function(let pts, let rt) = te, case .closure(let c) = arg.kind else { continue }
            let ps = try withBindings(b) { try pts.map { try resolve($0) } }
            if case .name(let n, _) = rt, gens.contains(n), b[n] == nil {
                let (_, t) = try withBindings(b) { try inlineClosure(c, ps, nil, ps.map { _ in "0" }) }
                try unify(rt, t, gens, &b)
            }
        }
        if let ret, let exp = expected { var tmp = b; try? unify(ret, exp, gens, &tmp); for (key, v) in tmp where b[key] == nil { b[key] = v } }
        if let o = owner, let st = ctx.selfType, let origin = st.origin, origin.template == o {   // Stack() inside Stack<T>'s own methods
            for (g, v) in zip(generics, origin.args) where b[g] == nil { b[g] = v }
        }
        for g in generics where b[g] == nil { throw fail("can't work out the type for '\(g)': write it out, like Name<Int>(...), or give the variable a type") }
        return b
    }

    func unify(_ te: TypeExpr, _ t: SType, _ gens: Set<String>, _ b: inout [String: SType]) throws {
        switch te {
        case .name(let n, let args):
            if gens.contains(n), args.isEmpty {
                if let old = b[n] { if old != t { throw fail("'\(n)' can't be both \(old.name) and \(t.name)") } } else { b[n] = t }
                return
            }
            if !args.isEmpty, case .named(let inst) = t, let o = types[inst]?.origin, o.template == n, o.args.count == args.count {
                for (a, x) in zip(args, o.args) { try unify(a, x, gens, &b) }
            }
        case .array(let e): if case .array(let x) = t { try unify(e, x, gens, &b) }
        case .optional(let e): if case .optional(let x) = t { try unify(e, x, gens, &b) } else { try unify(e, t, gens, &b) }
        case .dict(let k, let v): if case .dict(let kt, let vt) = t { try unify(k, kt, gens, &b); try unify(v, vt, gens, &b) }
        case .tuple(let items): if case .tuple(let es, _) = t, es.count == items.count { for (i, x) in items.enumerated() { try unify(x.type, es[i], gens, &b) } }
        case .function(let ps, let r):
            if case .fn(let pts, let rt) = t, pts.count == ps.count { for (i, x) in ps.enumerated() { try unify(x, pts[i], gens, &b) }; try unify(r, rt, gens, &b) }
        case .some: break
        }
    }

    func instantiateFunc(_ g: FuncDecl, _ b: [String: SType]) throws -> FuncInfo {
        let key = g.name + "__" + g.generics.map { b[$0]!.mangled }.joined(separator: "_")
        if let f = funcs[key] { return f }
        var decl = g
        decl.generics = []
        let saved = (curFile, curLine, curCol)
        var info = try withBindings(b) { try funcInfo(decl, owner: nil) }
        info.cName = "sw_\(key)"
        info.bindings = b
        funcs[key] = info
        protos.append(try prototype(info) + ";")
        (curFile, curLine, curCol) = saved
        return info
    }

    /// Which concrete types conform to each protocol, and a check that they provide what it asks for.
    func computeConformers() throws {
        let protocols = typeOrder.filter { types[$0]!.isProtocol }
        if protocols.isEmpty { return }
        func closure(_ names: [String]) -> Set<String> {
            var out = Set<String>()
            var work = names
            while let n = work.popLast() {
                if out.insert(n).inserted, let p = types[n], p.isProtocol { work += p.conformances }
            }
            return out
        }
        for pn in protocols { protocolConformers[pn] = [] }
        for n in typeOrder {
            let ti = types[n]!
            if ti.isProtocol { continue }
            let all = closure(ti.conformances)
            for pn in protocols where all.contains(pn) {
                curFile = ti.decl.file; curLine = ti.decl.line; curCol = 1
                // Requirements of this protocol and every protocol it inherits from.
                for rn in closure([pn]) {
                    guard let req = types[rn], req.isProtocol else { continue }
                    for m in req.methods.values {
                        guard let have = ti.methods[m.decl.name], have.params.count == m.params.count else { throw fail("'\(n)' doesn't conform to '\(rn)': it needs a method '\(m.decl.name)' with \(m.params.count) parameter\(m.params.count == 1 ? "" : "s")") }
                        if have.ret != m.ret { throw fail("'\(n)' doesn't conform to '\(rn)': '\(m.decl.name)' should return \(m.ret.name)") }
                    }
                    for p in req.props {
                        guard let have = ti.props.first(where: { $0.name == p.name }) else { throw fail("'\(n)' doesn't conform to '\(rn)': it needs a property '\(p.name)'") }
                        if have.type != p.type { throw fail("'\(n)' doesn't conform to '\(rn)': '\(p.name)' should be \(p.type.name)") }
                    }
                }
                protocolConformers[pn, default: []].append(n)
            }
        }
    }

    func funcInfo(_ f: FuncDecl, owner: TypeInfo?) throws -> FuncInfo {
        var params: [ParamInfo] = []
        for p in f.params {
            params.append(ParamInfo(label: p.label, name: p.name, type: try resolve(p.type), defaultValue: p.defaultValue, isInout: p.isInout))
        }
        let ret = try f.ret.map(resolve) ?? .void
        var cName: String
        if let o = owner {
            let prefix = o.isClass ? "C_" : "T_"
            cName = f.name == "init" ? (o.isClass ? "C_\(o.name)_new" : "T_\(o.name)_init") : "\(prefix)\(o.name)_\(f.name)"
        } else { cName = "sw_\(f.name)" }
        return FuncInfo(decl: f, owner: owner?.name, params: params, ret: f.name == "init" ? (owner!.isClass ? .named(owner!.name) : .named(owner!.name)) : ret, cName: cName, isStatic: f.isStatic || owner == nil)
    }

    func prototype(_ f: FuncInfo) throws -> String {
        curFile = f.decl.file; curLine = f.decl.line; curCol = f.decl.col
        var params: [String] = []
        if let o = f.owner, let ti = types[o], !f.isStatic, f.decl.name != "init" { params.append(ti.isClass ? "C_\(o) *self" : "T_\(o) *self") }
        for p in f.params {
            if case .array = p.type, p.isInout == false { /* by value */ }
            let c = try ctype(p.type)
            params.append(p.isInout ? "\(c) *\(cname(p.name))" : try decl(p.type, cname(p.name)))
        }
        let ret = try decl(f.ret, "\(f.cName)(\(params.isEmpty ? "void" : params.joined(separator: ", ")))")
        return "static __attribute__((unused)) \(ret)"
    }

    func accessorPrototype(_ ti: TypeInfo, _ p: PropInfo, setter: Bool) throws -> String {
        let selfParam = ti.isClass ? "C_\(ti.name) *self" : "T_\(ti.name) *self"
        let prefix = ti.isClass ? "C_" : "T_"
        if p.decl.isStatic {
            return setter ? "static __attribute__((unused)) void \(prefix)\(ti.name)_set_\(p.name)(\(try decl(p.type, "newValue")))"
                          : "static __attribute__((unused)) \(try decl(p.type, "\(prefix)\(ti.name)_get_\(p.name)(void)"))"
        }
        if setter { return "static __attribute__((unused)) void \(prefix)\(ti.name)_set_\(p.name)(\(selfParam), \(try decl(p.type, "newValue")))" }
        return "static __attribute__((unused)) \(try decl(p.type, "\(prefix)\(ti.name)_get_\(p.name)(\(selfParam))"))"
    }

    // MARK: Globals and statics

    func declareGlobals() throws {
        for g in prog.globals {
            curFile = g.file
            guard case .decl(let pat, let type, let value, let isLet) = g.stmt.kind else { continue }
            at(g.stmt)
            ctx = FnCtx()
            switch pat {
            case .name(let name):
                if globals[name] != nil || funcs[name] != nil { throw fail("invalid redeclaration of '\(name)'") }
                let (t, line) = try declare(name: "sw_\(name)", type: type, value: value, global: true)
                globals[name] = Local(type: t, c: "sw_\(name)", isLet: isLet)
                if isLet, let v = value, case .int(let n) = v.kind { constInts[name] = n }
                globalDecls.append("static __attribute__((unused)) \(try decl(t, "sw_\(name)"));")
                initLines.append(line)
            default: throw fail("global tuple declarations aren't supported")
            }
        }
    }

    /// Static properties of a type become globals.
    func declareStatics(for ti: TypeInfo) throws {
        let n = ti.name
        for p in ti.props where p.decl.isStatic && !p.isComputed {
            curFile = ti.decl.file; curLine = p.decl.line; curCol = p.decl.col
            ctx = FnCtx(); ctx.selfType = ti; ctx.isStatic = true
            let c = "\(ti.isClass ? "C_" : "T_")\(n)_\(p.name)"
            guard let v = p.decl.value else { throw fail("a static property needs a value") }
            let (t, line) = try declare(name: c, type: p.decl.type, value: v, global: true)
            _ = t
            globalDecls.append("static __attribute__((unused)) \(try decl(p.type, c));")
            initLines.append(line)
            if p.decl.isLet, case .int(let k) = v.kind { constInts["\(n).\(p.name)"] = k }
        }
    }

    /// The type of an expression with no context (used for properties declared without a type).
    func inferType(_ e: Expr) throws -> SType {
        ctx = FnCtx()
        return try expr(e, nil).1
    }

    // MARK: Functions

    func function(_ f: FuncInfo) throws -> String {
        if f.bindings.isEmpty { return try functionImpl(f) }
        return try withBindings(f.bindings) { try functionImpl(f) }
    }

    func functionImpl(_ f: FuncInfo) throws -> String {
        curFile = f.decl.file
        ctx = FnCtx()
        ctx.ret = f.ret
        if let o = f.owner { ctx.selfType = types[o]; ctx.isMutating = f.decl.isMutating || types[o]!.isClass }
        ctx.isStatic = f.isStatic
        if f.cName.hasPrefix("sw_local") { ctx.localFuncs[f.decl.name] = f }
        for p in f.params {
            let c = cname(p.name)
            ctx.scopes[0][p.name] = Local(type: p.type, c: p.isInout ? "(*\(c))" : c, isLet: !p.isInout)
        }
        ctx.viewMode = f.ret == .view
        let body = try functionBody(f.decl.body, ret: f.ret)
        let voidSelf = f.owner != nil && !f.isStatic ? "    (void)self;\n" : ""
        return try prototype(f) + " {\n" + voidSelf + body + "}\n"
    }

    /// A function body; a lone expression is the return value, as in Swift.
    func functionBody(_ stmts: [Stmt], ret: SType) throws -> String {
        if ret == .view { return try block(stmts, indent: 1) }
        if ret != .void, stmts.count == 1, case .expr(let e) = stmts[0].kind {
            at(stmts[0])
            return "    return \(try coerce(e, to: ret));\n"
        }
        return try block(stmts, indent: 1)
    }

    func initializer(_ ti: TypeInfo, _ f: FuncInfo) throws -> String {
        curFile = f.decl.file
        ctx = FnCtx()
        ctx.selfType = ti; ctx.isMutating = true; ctx.isInit = true
        for p in f.params {
            let c = cname(p.name)
            ctx.scopes[0][p.name] = Local(type: p.type, c: p.isInout ? "(*\(c))" : c, isLet: true)
        }
        var out = try prototype(f) + " {\n"
        let name = ti.name
        if ti.isClass {
            out += "    C_\(name) *self = (C_\(name) *)calloc(1, sizeof(C_\(name)));\n    if (!self) ws_fatal();\n"
        } else {
            out += "    T_\(name) _s_ = {0};\n    T_\(name) *self = &_s_;\n"
        }
        out += try propertyDefaults(ti)
        out += try block(f.decl.body, indent: 1)
        out += ti.isClass ? "    return self;\n}\n" : "    return _s_;\n}\n"
        return out
    }

    func defaultClassInit(_ ti: TypeInfo) throws -> String {
        ctx = FnCtx(); ctx.selfType = ti; ctx.isMutating = true; ctx.isInit = true
        var out = "static __attribute__((unused)) C_\(ti.name) *C_\(ti.name)_new(void) {\n"
        out += "    C_\(ti.name) *self = (C_\(ti.name) *)calloc(1, sizeof(C_\(ti.name)));\n    if (!self) ws_fatal();\n"
        out += try propertyDefaults(ti)
        return out + "    return self;\n}\n"
    }

    func propertyDefaults(_ ti: TypeInfo) throws -> String {
        var out = ""
        for p in ti.storedProps {
            guard let v = p.decl.value else { continue }
            curLine = p.decl.line; curCol = p.decl.col
            let saved = ctx.scopes
            ctx.scopes = [[:]]
            let c = try coerce(v, to: p.type)
            ctx.scopes = saved
            out += "    self->\(cname(p.name)) = \(c);\n"
        }
        return out
    }

    func accessors(_ ti: TypeInfo, _ p: PropInfo) throws -> [String] {
        var out: [String] = []
        curFile = ti.decl.file; curLine = p.decl.line; curCol = p.decl.col
        ctx = FnCtx(); ctx.selfType = ti; ctx.isMutating = false; ctx.isStatic = p.decl.isStatic; ctx.ret = p.type
        ctx.viewMode = p.type == .view
        let voidSelf = p.decl.isStatic ? "" : "    (void)self;\n"
        out.append(try accessorPrototype(ti, p, setter: false) + " {\n" + voidSelf + (try functionBody(p.decl.getter ?? [], ret: p.type)) + "}\n")
        if let s = p.decl.setter {
            ctx = FnCtx(); ctx.selfType = ti; ctx.isMutating = true; ctx.isStatic = p.decl.isStatic
            ctx.scopes[0][s.param] = Local(type: p.type, c: "newValue", isLet: true)
            var body = ""
            if s.param != "newValue" { body = "    " + (try decl(p.type, cname(s.param))) + " = newValue;\n"; ctx.scopes[0][s.param] = Local(type: p.type, c: cname(s.param), isLet: true) }
            out.append(try accessorPrototype(ti, p, setter: true) + " {\n" + voidSelf + body + (try block(s.body, indent: 1)) + "}\n")
        }
        return out
    }
}
