import Foundation

/// Parser for the Swift subset Revolution Editor translates to C. Supported: functions (labels,
/// defaults, inout), let/var, structs, classes (no inheritance), enums (with raw values),
/// extensions, computed and static members, optionals, tuples, arrays, closures, guard/if-let,
/// property wrappers (@State and friends), trailing closures and the SwiftUI declaration syntax.
/// Not supported (reported as errors): protocols, generics, inheritance, enum payloads,
/// error handling, async, operators, key paths.
nonisolated struct SwiftParser {
    private var toks: [Token]
    private var p = 0
    let file: String
    /// Set while parsing a condition or loop header, where `{` starts a block, not a trailing closure.
    private var noTrailing = false
    private var shorthandStack: [Int] = []

    init(source: String, file: String) throws {
        self.file = file
        self.toks = try SwiftLexer.lex(source, file: file)
    }

    private init(tokens: [Token], file: String) {
        self.toks = tokens
        self.file = file
    }

    static func parse(source: String, file: String, into program: inout SwiftProgram) throws {
        var parser = try SwiftParser(source: source, file: file)
        try parser.parseTopLevel(into: &program)
    }

    // MARK: Helpers

    private var cur: Token { toks[p] }
    private func peek(_ n: Int = 1) -> Token { toks[min(p + n, toks.count - 1)] }
    private func err(_ m: String, at t: Token? = nil) -> SwiftError {
        let t = t ?? cur
        return SwiftError(file: file, line: t.line, col: t.col, message: m)
    }
    @discardableResult private mutating func advance() -> Token { let t = toks[p]; if p < toks.count - 1 { p += 1 }; return t }
    private func isPunct(_ s: String) -> Bool { if case .punct(let x) = cur.tok { return x == s }; return false }
    private func isOp(_ s: String) -> Bool { if case .op(let x) = cur.tok { return x == s }; return false }
    private func isKw(_ s: String) -> Bool { if case .keyword(let x) = cur.tok { return x == s }; return false }
    private func isIdent(_ s: String) -> Bool { if case .ident(let x) = cur.tok { return x == s }; return false }
    private mutating func eatPunct(_ s: String) -> Bool { if isPunct(s) { advance(); return true }; return false }
    private mutating func eatOp(_ s: String) -> Bool { if isOp(s) { advance(); return true }; return false }
    private mutating func eatKw(_ s: String) -> Bool { if isKw(s) { advance(); return true }; return false }
    private mutating func expectPunct(_ s: String) throws { if !eatPunct(s) { throw err("expected '\(s)'") } }
    private mutating func ident(_ what: String = "a name") throws -> String {
        if case .ident(let n) = cur.tok { advance(); return n }
        throw err("expected \(what)")
    }
    /// An identifier or keyword used as an argument label (`in:`, `where:`, `at:`).
    private func labelWord(_ t: Token) -> String? {
        switch t.tok {
        case .ident(let n): return n
        case .keyword(let k): return k
        default: return nil
        }
    }

    private var atEOF: Bool { if case .eof = cur.tok { return true }; return false }

    private static let unsupported: [String: String] = [
        "defer": "defer isn't supported", "do": "do/catch isn't supported",
        "try": "errors (try/throw) aren't supported", "catch": "do/catch isn't supported", "throw": "errors (try/throw) aren't supported",
        "throws": "errors (try/throw) aren't supported", "rethrows": "errors (try/throw) aren't supported",
        "async": "async/await isn't supported", "await": "async/await isn't supported",
        "where": "'where' isn't supported", "is": "'is' isn't supported", "as": "'as' casts aren't supported; use Int(x) / Double(x)",
        "subscript": "custom subscripts aren't supported", "operator": "custom operators aren't supported",
        "associatedtype": "protocols aren't supported", "fallthrough": "fallthrough isn't supported", "Any": "'Any' isn't supported",
        "deinit": "deinit isn't supported (objects are never freed)",
    ]

    private func unsupportedError(_ t: Token) -> SwiftError? {
        if case .keyword(let k) = t.tok, let why = Self.unsupported[k] { return err(why, at: t) }
        return nil
    }

    // MARK: Attributes and modifiers

    private static let modifierWords: Set<String> = ["private", "fileprivate", "public", "internal", "open", "final", "lazy", "required", "nonisolated", "override", "convenience", "indirect", "dynamic"]

    private mutating func parseModifiers() throws -> (attrs: Set<String>, isStatic: Bool, isMutating: Bool) {
        var attrs = Set<String>(), isStatic = false, isMutating = false
        while true {
            if isPunct("@") {
                advance()
                let name: String
                if case .ident(let n) = cur.tok { name = n } else if case .keyword(let k) = cur.tok { name = k } else { throw err("expected an attribute name") }
                advance()
                if isPunct("("), !cur.spaceBefore { try skipBalanced("(", ")") }
                attrs.insert(name)
            } else if isKw("static") { advance(); isStatic = true }
            else if isKw("class"), case .keyword(let k) = peek().tok, k == "func" || k == "var" || k == "let" { advance(); isStatic = true }
            else if isKw("mutating") { advance(); isMutating = true }
            else if case .ident(let w) = cur.tok, Self.modifierWords.contains(w), peek().newlineBefore == false {
                if w == "override" { throw err("inheritance isn't supported") }
                if w == "convenience" { throw err("convenience initialisers aren't supported") }
                advance()
            } else { return (attrs, isStatic, isMutating) }
        }
    }

    // Skips from an opening token to its matching close, counting nesting so inner pairs don't
    // end it early. Used for bodies we don't need to understand.
    private mutating func skipBalanced(_ open: String, _ close: String) throws {
        var depth = 0
        repeat {
            if isPunct(open) { depth += 1 } else if isPunct(close) { depth -= 1 }
            if atEOF { throw err("missing '\(close)'") }
            advance()
        } while depth > 0
    }

    // MARK: Top level and declarations

    mutating func parseTopLevel(into prog: inout SwiftProgram) throws {
        while true {
            _ = eatPunct(";")
            if atEOF { return }
            if isKw("import") { advance(); _ = try ident("a module name"); while eatPunct(".") { _ = try ident() }; continue }
            let (attrs, isStatic, _) = try parseModifiers()
            if isKw("func") { var f = try parseFunc(); f.isStatic = isStatic; prog.funcs.append(f); continue }
            if isKw("struct") || isKw("class") || isKw("enum") { prog.types.append(try parseTypeDecl(attrs: attrs)); continue }
            if isKw("protocol") { prog.types.append(try parseProtocol()); continue }
            if isKw("extension") { prog.extensions.append(try parseExtension()); continue }
            if isKw("typealias") {
                let t = advance()
                let name = try ident("a name")
                guard eatOp("=") else { throw err("expected '='") }
                prog.aliases.append((name, try parseType(), file, t.line)); continue
            }
            if isKw("let") || isKw("var") {
                for s in try parseDecl() { prog.globals.append(GlobalDecl(stmt: s, file: file)) }
                continue
            }
            if let e = unsupportedError(cur) { throw e }
            throw err("only functions, types and variables can go at the top level")
        }
    }

    private mutating func parseConformances() throws -> [String] {
        var out: [String] = []
        if eatPunct(":") {
            repeat { out.append(try typeName()); if isOp("<") { throw err("generics aren't supported") } } while eatPunct(",")
        }
        if isKw("where") { throw err("'where' isn't supported") }
        return out
    }

    private mutating func typeName() throws -> String {
        var n: String
        if case .ident(let x) = cur.tok { n = x } else if case .keyword(let k) = cur.tok, k == "Self" || k == "Any" { n = k } else { throw err("expected a type name") }
        advance()
        while isPunct("."), case .ident(let more) = peek().tok { advance(); advance(); n += "." + more }
        return n
    }

    private static let knownProtocols: Set<String> = ["View", "App", "Scene", "ObservableObject", "Identifiable", "Hashable", "Equatable", "Comparable", "CaseIterable", "Codable", "Encodable", "Decodable", "Sendable", "CustomStringConvertible", "RawRepresentable"]
    private static let rawTypes: Set<String> = ["Int", "String", "UInt8", "UInt32", "Double", "Float", "Int32", "UInt"]

    private mutating func parseTypeDecl(attrs: Set<String>) throws -> TypeDecl {
        let start = advance()
        let kind: TypeDecl.Kind = { if case .keyword("class") = start.tok { return .classType }; if case .keyword("enum") = start.tok { return .enumType }; return .structType }()
        let name = try ident("a type name")
        let generics = try parseGenericParams()
        var conf = try parseConformances()
        var raw: TypeExpr?
        if kind == .enumType, let f = conf.first, Self.rawTypes.contains(f) { raw = .name(f, []); conf.removeFirst() }
        var decl = TypeDecl(kind: kind, name: name, conformances: conf, rawType: raw, isMain: attrs.contains("main"), generics: generics, line: start.line, file: file)
        try expectPunct("{")
        try parseMembers(into: &decl.props, methods: &decl.methods, inits: &decl.inits, cases: &decl.cases, isEnum: kind == .enumType)
        try expectPunct("}")
        return decl
    }

    /// `protocol Shape: Named { var area: Double { get }; func draw() }`
    private mutating func parseProtocol() throws -> TypeDecl {
        let start = advance()
        let name = try ident("a protocol name")
        if isOp("<") { throw err("generics aren't supported") }
        let parents = try parseConformances()
        var decl = TypeDecl(kind: .protocolType, name: name, conformances: parents, line: start.line, file: file)
        try expectPunct("{")
        while !isPunct("}") {
            if atEOF { throw err("missing '}'") }
            if eatPunct(";") { continue }
            let (_, isStatic, isMutating) = try parseModifiers()
            if isKw("func") {
                let f = advance()
                let n = try ident("a function name")
                if isOp("<") { throw err("generics aren't supported") }
                let params = try parseParams()
                var ret: TypeExpr?
                if eatOp("->") { ret = try parseType() }
                decl.methods.append(FuncDecl(name: n, params: params, ret: ret, body: [], isMutating: isMutating, isStatic: isStatic, isRequirement: true, line: f.line, col: f.col, file: file))
            } else if isKw("var") {
                let v = advance()
                let n = try ident("a property name")
                try expectPunct(":")
                let t = try parseType()
                try expectPunct("{")
                var settable = false
                while !isPunct("}") { if isIdent("set") { settable = true }; advance() }
                try expectPunct("}")
                var pd = PropDecl(name: n, type: t, value: nil, isLet: !settable, isStatic: isStatic, attrs: ["requirement"], getter: nil, setter: nil, line: v.line, col: v.col)
                pd.isLet = !settable
                decl.props.append(pd)
            } else if isKw("associatedtype") || isKw("init") || isKw("subscript") {
                throw err("this kind of protocol requirement isn't supported")
            } else { throw err("expected a property or method requirement") }
        }
        try expectPunct("}")
        return decl
    }

    private mutating func parseExtension() throws -> ExtensionDecl {
        let start = advance()
        let name = try typeName()
        let conf = try parseConformances()
        try expectPunct("{")
        var props: [PropDecl] = [], methods: [FuncDecl] = [], inits: [FuncDecl] = [], cases: [(name: String, raw: Expr?, payload: [(label: String?, type: TypeExpr)])] = []
        try parseMembers(into: &props, methods: &methods, inits: &inits, cases: &cases, isEnum: false)
        try expectPunct("}")
        return ExtensionDecl(typeName: name, conformances: conf, props: props, methods: methods, inits: inits, line: start.line, file: file)
    }

    private mutating func parseMembers(into props: inout [PropDecl], methods: inout [FuncDecl], inits: inout [FuncDecl],
                                       cases: inout [(name: String, raw: Expr?, payload: [(label: String?, type: TypeExpr)])], isEnum: Bool) throws {
        while !isPunct("}") {
            if atEOF { throw err("missing '}'") }
            if eatPunct(";") { continue }
            if isKw("case"), isEnum {
                advance()
                repeat {
                    let n = try ident("a case name")
                    var payload: [(label: String?, type: TypeExpr)] = []
                    if eatPunct("(") {
                        while !isPunct(")") {
                            var label: String?
                            if case .ident(let l) = cur.tok, case .punct(":") = peek().tok { label = l; advance(); advance() }
                            payload.append((label, try parseType()))
                            if !eatPunct(",") { break }
                        }
                        try expectPunct(")")
                    }
                    var raw: Expr?
                    if eatOp("=") { raw = try parseExpr() }
                    cases.append((n, raw, payload))
                } while eatPunct(",")
                continue
            }
            let (attrs, isStatic, isMutating) = try parseModifiers()
            if isKw("func") { var f = try parseFunc(); f.isStatic = isStatic; f.isMutating = isMutating; methods.append(f); continue }
            if isKw("init") {
                let t = advance()
                if isOp("?") || isOp("!") { throw err("failable initialisers aren't supported") }
                let params = try parseParams()
                let body = try parseBlock()
                inits.append(FuncDecl(name: "init", params: params, ret: nil, body: body, isMutating: true, line: t.line, col: t.col, file: file))
                continue
            }
            if isKw("deinit") { advance(); _ = try parseBlock(); continue }
            if isKw("var") || isKw("let") { props.append(try parseProperty(attrs: attrs, isStatic: isStatic)); continue }
            if isKw("typealias") { throw err("typealias inside a type isn't supported; put it at the top level") }
            if isKw("struct") || isKw("class") || isKw("enum") { throw err("nested types aren't supported; declare it at the top level") }
            if let e = unsupportedError(cur) { throw e }
            throw err("expected a property or method")
        }
    }

    private mutating func parseProperty(attrs: Set<String>, isStatic: Bool) throws -> PropDecl {
        let start = advance()
        let isLet = { if case .keyword("let") = start.tok { return true }; return false }()
        let name = try ident("a property name")
        var type: TypeExpr?
        if eatPunct(":") { type = try parseType() }
        var prop = PropDecl(name: name, type: type, value: nil, isLet: isLet, isStatic: isStatic, attrs: attrs, getter: nil, setter: nil, line: start.line, col: start.col)
        if isOp("=") { advance(); prop.value = try parseExpr() }
        if isPunct("{") {
            // Computed: `{ body }` or `{ get { } set { } }`.
            advance()
            if isIdent("get") || isIdent("set") || isIdent("willSet") || isIdent("didSet") {
                while !isPunct("}") {
                    if isIdent("get") { advance(); prop.getter = try parseBlock() }
                    else if isIdent("set") {
                        advance()
                        var param = "newValue"
                        if eatPunct("(") { param = try ident(); try expectPunct(")") }
                        prop.setter = (param, try parseBlock())
                    } else { throw err("property observers (willSet/didSet) aren't supported") }
                }
            } else {
                prop.getter = try parseStmtsUntilBrace()
            }
            try expectPunct("}")
            if prop.type == nil { throw err("a computed property needs a type", at: start) }
        }
        return prop
    }

    private mutating func parseParams() throws -> [Param] {
        try expectPunct("(")
        var params: [Param] = []
        while !isPunct(")") {
            var label: String?, local: String
            guard let a = labelWord(cur) else { throw err("expected a parameter name") }
            advance()
            if case .ident(let b) = cur.tok { advance(); label = a; local = b } else { label = a; local = a }
            if label == "_" { label = nil }
            try expectPunct(":")
            var isInout = false
            if isKw("inout") { advance(); isInout = true }
            while isPunct("@") { advance(); advance() }   // @escaping etc.
            let t = try parseType()
            var def: Expr?
            if eatOp("=") { def = try parseExpr() }
            if isOp("...") { throw err("variadic parameters aren't supported") }
            params.append(Param(label: label, name: local, type: t, defaultValue: def, isInout: isInout))
            if !eatPunct(",") { break }
        }
        try expectPunct(")")
        return params
    }

    private mutating func parseFunc() throws -> FuncDecl {
        let start = advance()   // func
        let name = try ident("a function name")
        let generics = try parseGenericParams()
        let params = try parseParams()
        var ret: TypeExpr?
        if let e = unsupportedError(cur) { throw e }
        if eatOp("->") { ret = try parseType() }
        if let e = unsupportedError(cur) { throw e }
        let body = try parseBlock()
        var f = FuncDecl(name: name, params: params, ret: ret, body: body, line: start.line, col: start.col, file: file)
        f.generics = generics
        return f
    }

    // MARK: Generics

    /// `<T, U: Comparable>`, the names; constraints are skipped (types are specialised by use).
    private mutating func parseGenericParams() throws -> [String] {
        guard eatOp("<") else { return [] }
        var names: [String] = []
        repeat {
            names.append(try ident("a type parameter name"))
            if eatPunct(":") {
                _ = try typeName()
                while eatOp("&") { _ = try typeName() }
            }
        } while eatPunct(",")
        guard eatOp(">") else { throw err("expected '>'") }
        if isKw("where") { throw err("'where' isn't supported") }
        return names
    }

    // MARK: Types

    private mutating func parseType() throws -> TypeExpr {
        var t: TypeExpr
        if isPunct("[") {
            advance()
            let e = try parseType()
            if eatPunct(":") {
                let v = try parseType()
                try expectPunct("]")
                t = .dict(e, v)
            } else {
                try expectPunct("]")
                t = .array(e)
            }
        } else if isPunct("(") {
            advance()
            var elems: [(label: String?, type: TypeExpr)] = []
            while !isPunct(")") {
                var label: String?
                if case .ident(let l) = cur.tok, case .punct(":") = peek().tok { label = l; advance(); advance() }
                elems.append((label, try parseType()))
                if !eatPunct(",") { break }
            }
            try expectPunct(")")
            if eatOp("->") {
                let r = try parseType()
                t = .function(elems.map(\.type), r)
            } else if elems.count == 1, elems[0].label == nil {
                t = elems[0].type
            } else {
                t = .tuple(elems)
            }
        } else if isIdent("some") {
            advance()
            t = .some(try parseType())
        } else {
            let name = try typeName()
            var args: [TypeExpr] = []
            if isOp("<") {   // Binding<Bool>
                advance()
                repeat { args.append(try parseType()) } while eatPunct(",")
                if isOp(">>") { toks[p].tok = .op(">") }             // Array<Array<Int>>: the first > is consumed, one remains
                else { guard eatOp(">") else { throw err("expected '>'") } }
            }
            t = .name(name, args)
        }
        while (isOp("?") || isOp("!")), !cur.spaceBefore { advance(); t = .optional(t) }
        return t
    }

    // MARK: Statements

    private mutating func parseBlock() throws -> [Stmt] {
        try expectPunct("{")
        let out = try parseStmtsUntilBrace()
        try expectPunct("}")
        return out
    }

    private mutating func parseStmtsUntilBrace() throws -> [Stmt] {
        var out: [Stmt] = []
        while !isPunct("}") {
            if atEOF { throw err("missing '}'") }
            if eatPunct(";") { continue }
            out.append(contentsOf: try parseStmt())
        }
        return out
    }

    private mutating func parsePattern() throws -> Pattern {
        if eatPunct("(") {
            var items: [Pattern] = []
            while !isPunct(")") { items.append(try parsePattern()); if !eatPunct(",") { break } }
            try expectPunct(")")
            return .tuple(items)
        }
        let n = try ident("a name")
        return n == "_" ? .wildcard : .name(n)
    }

    private mutating func parseDecl() throws -> [Stmt] {
        let start = advance()
        let isLet = { if case .keyword("let") = start.tok { return true }; return false }()
        var out: [Stmt] = []
        repeat {
            let pat = try parsePattern()
            var type: TypeExpr?
            if eatPunct(":") { type = try parseType() }
            var value: Expr?
            if eatOp("=") { value = try parseExpr() }
            if type == nil && value == nil { throw err("a variable needs a type or a value") }
            out.append(Stmt(kind: .decl(pat, type, value, isLet: isLet), line: start.line, col: start.col))
        } while eatPunct(",")
        return out
    }

    /// `a, let b = c, d`, the condition list of if / guard / while.
    private mutating func parseConditions() throws -> [Condition] {
        let saved = noTrailing
        noTrailing = true
        defer { noTrailing = saved }
        var out: [Condition] = []
        repeat {
            if isKw("let") || isKw("var") {
                let isVar = isKw("var")
                advance()
                let pat = try parsePattern()
                if eatOp("=") { out.append(.bind(pat, try parseExpr(), isVar: isVar)) }
                else if case .name(let n) = pat { out.append(.bind(pat, Expr(kind: .ident(n), line: cur.line, col: cur.col), isVar: isVar)) }   // if let x
                else { throw err("expected '='") }
            } else if isKw("case") {
                advance()
                let pat = try parseCasePattern()
                guard eatOp("=") else { throw err("expected '=' in 'if case'") }
                out.append(.match(pat, try parseExpr()))
            } else {
                out.append(.bool(try parseExpr()))
            }
        } while eatPunct(",")
        return out
    }

    private mutating func parseStmt() throws -> [Stmt] {
        let t = cur
        func mk(_ k: Stmt.Kind) -> [Stmt] { [Stmt(kind: k, line: t.line, col: t.col)] }
        if isKw("let") || isKw("var") { return try parseDecl() }
        if isKw("if") {
            advance()
            let conds = try parseConditions()
            let then = try parseBlock()
            var els: [Stmt]?
            if eatKw("else") {
                if isKw("if") { els = try parseStmt() } else { els = try parseBlock() }
            }
            return mk(.ifElse(conds, then: then, else: els))
        }
        if isKw("guard") {
            advance()
            let conds = try parseConditions()
            guard eatKw("else") else { throw err("expected 'else' after guard") }
            return mk(.guardElse(conds, else: try parseBlock()))
        }
        if isKw("while") {
            advance()
            let conds = try parseConditions()
            return mk(.whileLoop(conds, body: try parseBlock()))
        }
        if isKw("repeat") {
            advance()
            let body = try parseBlock()
            guard eatKw("while") else { throw err("expected 'while' after repeat block") }
            let saved = noTrailing; noTrailing = true
            let c = try parseExpr()
            noTrailing = saved
            return mk(.repeatWhile(body: body, cond: c))
        }
        if isKw("for") {
            advance()
            let pat = try parsePattern()
            guard eatKw("in") else { throw err("expected 'in'") }
            let saved = noTrailing; noTrailing = true
            let seq = try parseExpr()
            noTrailing = saved
            if isKw("where") { throw err("'where' isn't supported") }
            return mk(.forIn(pat, seq, body: try parseBlock()))
        }
        if isKw("switch") {
            advance()
            let saved = noTrailing; noTrailing = true
            let subject = try parseExpr()
            noTrailing = saved
            try expectPunct("{")
            var cases: [(patterns: [Expr], body: [Stmt])] = []
            var def: [Stmt]?
            while !isPunct("}") {
                if eatKw("default") {
                    try expectPunct(":")
                    def = try parseCaseBody()
                } else if eatKw("case") {
                    var pats = [try parseCasePattern()]
                    while eatPunct(",") { pats.append(try parseCasePattern()) }
                    try expectPunct(":")
                    cases.append((pats, try parseCaseBody()))
                } else { throw err("expected 'case' or 'default'") }
            }
            try expectPunct("}")
            return mk(.switchOn(subject, cases: cases, default: def))
        }
        if isKw("return") {
            advance()
            if isPunct("}") || cur.newlineBefore || isPunct(";") { return mk(.ret(nil)) }
            return mk(.ret(try parseExpr()))
        }
        if isKw("break") { advance(); return mk(.brk) }
        if isKw("continue") { advance(); return mk(.cont) }
        if isKw("func") { return mk(.localFunc(try parseFunc())) }
        if isKw("struct") || isKw("class") || isKw("enum") { throw err("types must be declared at the top level") }
        if let e = unsupportedError(t) { throw e }

        let lhs = try parseExpr()
        if case .op(let o) = cur.tok, ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="].contains(o) {
            advance()
            return mk(.assign(op: o, lhs: lhs, rhs: try parseExpr()))
        }
        return mk(.expr(lhs))
    }

    /// A switch / if-case pattern: an expression, where `let x` inside an enum case's parentheses
    /// binds a value.
    private mutating func parseCasePattern() throws -> Expr {
        if isKw("let") || isKw("var") {
            // case let .circle(r):  ==  case .circle(let r):
            advance()
            var e = try parsePatternExpr()
            if case .call(let callee, let args) = e.kind {
                let rewritten = args.map { a -> Arg in
                    if case .ident(let n) = a.value.kind, n != "_" { return Arg(label: a.label, value: Expr(kind: .letPattern(n), line: a.value.line, col: a.value.col)) }
                    return a
                }
                e = Expr(kind: .call(callee, rewritten), line: e.line, col: e.col)
            }
            return e
        }
        return try parsePatternExpr()
    }

    private mutating func parsePatternExpr() throws -> Expr {
        let t = cur
        // `.name(let a, let b)`
        if isPunct("."), case .ident = peek().tok {
            advance()
            let name = try ident()
            let head = Expr(kind: .implicitMember(name), line: t.line, col: t.col)
            guard isPunct("("), !cur.newlineBefore else { return head }
            advance()
            var args: [Arg] = []
            while !isPunct(")") {
                var label: String?
                if let l = labelWord(cur), case .punct(":") = peek().tok { label = l; advance(); advance() }
                if isKw("let") || isKw("var") {
                    advance()
                    let n = try ident("a name")
                    args.append(Arg(label: label, value: Expr(kind: n == "_" ? .ident("_") : .letPattern(n), line: cur.line, col: cur.col)))
                } else {
                    args.append(Arg(label: label, value: try parseExpr()))
                }
                if !eatPunct(",") { break }
            }
            try expectPunct(")")
            return Expr(kind: .call(head, args), line: t.line, col: t.col)
        }
        return try parseExpr()
    }

    private mutating func parseCaseBody() throws -> [Stmt] {
        var out: [Stmt] = []
        while !isKw("case"), !isKw("default"), !isPunct("}") {
            if atEOF { throw err("missing '}'") }
            if eatPunct(";") { continue }
            out.append(contentsOf: try parseStmt())
        }
        if out.isEmpty { throw err("a case needs at least one statement") }
        return out
    }

    // MARK: Expressions

    private static let precedence: [String: Int] = [
        "<<": 160, ">>": 160, "*": 150, "/": 150, "%": 150, "&": 150, "+": 140, "-": 140, "|": 140, "^": 140,
        "..<": 135, "...": 135, "??": 132, "==": 130, "!=": 130, "<": 130, ">": 130, "<=": 130, ">=": 130, "&&": 120, "||": 110,
    ]

    mutating func parseExpr() throws -> Expr { try parseTernary() }

    private mutating func parseTernary() throws -> Expr {
        let c = try parseBinary(0)
        if isOp("?") {
            advance()
            let saved = noTrailing; noTrailing = false
            let a = try parseTernary()
            noTrailing = saved
            try expectPunct(":")
            let b = try parseTernary()
            return Expr(kind: .ternary(c, a, b), line: c.line, col: c.col)
        }
        return c
    }

    // Precedence climbing: keep folding operators into `lhs` while they bind at least as tightly
    // as `minPrec`. Passing `prec + 1` for the right side makes operators left-associative;
    // `??` passes `prec` so it chains to the right. An operator at the start of a new line
    // is left alone, since Swift treats that as a new statement.
    private mutating func parseBinary(_ minPrec: Int) throws -> Expr {
        var lhs = try parseUnary()
        while case .op(let o) = cur.tok, let prec = Self.precedence[o], prec >= minPrec, !cur.newlineBefore {
            if o == "?" { break }
            let opTok = advance()
            let rhs = try parseBinary(o == "??" ? prec : prec + 1)
            if o == "..<" || o == "..." { lhs = Expr(kind: .range(lhs, rhs, inclusive: o == "..."), line: opTok.line, col: opTok.col) }
            else { lhs = Expr(kind: .binary(o, lhs, rhs), line: opTok.line, col: opTok.col) }
        }
        return lhs
    }

    private mutating func parseUnary() throws -> Expr {
        let t = cur
        if case .op(let o) = t.tok, case .punct(let next) = peek().tok, next == ")" || next == ",", Self.precedence[o] != nil {
            return try parsePrimary()   // an operator used as a function: reduce(0, +)
        }
        if case .op(let o) = t.tok, o == "-" || o == "!" || o == "~" || o == "+" {
            advance()
            let e = try parseUnary()
            if o == "+" { return e }
            return Expr(kind: .unary(o, e), line: t.line, col: t.col)
        }
        if case .op("&") = t.tok {
            advance()
            return Expr(kind: .inoutRef(try parseUnary()), line: t.line, col: t.col)
        }
        if let e = unsupportedError(t) { throw e }
        return try parsePostfix()
    }

    // Only names, calls and member accesses can be followed by a trailing `{ ... }`. Anything
    // else (a literal, say) means the brace belongs to something else, like an `if` body.
    private func canTakeTrailingClosure(_ e: Expr) -> Bool {
        switch e.kind {
        case .ident, .call, .member: return true
        default: return false
        }
    }

    private mutating func parsePostfix() throws -> Expr {
        var e = try parsePrimary()
        while true {
            // `.member` may start the next line (SwiftUI modifier chains).
            if isPunct("."), (!cur.newlineBefore || { if case .ident = peek().tok { return true }; return false }()) {
                advance()
                if case .int(let n) = cur.tok { advance(); e = Expr(kind: .tupleIndex(e, n), line: e.line, col: e.col); continue }
                let name: String
                if case .ident(let n) = cur.tok { name = n } else if case .keyword(let k) = cur.tok, k == "init" || k == "self" { name = k } else { throw err("expected a member name") }
                advance()
                e = Expr(kind: .member(e, name, optional: false), line: e.line, col: e.col)
            } else if isOp("?"), !cur.spaceBefore, case .punct(".") = peek().tok {
                advance(); advance()
                guard case .ident(let name) = cur.tok else { throw err("expected a member name") }
                advance()
                e = Expr(kind: .member(e, name, optional: true), line: e.line, col: e.col)
            } else if isOp("!"), !cur.spaceBefore, !cur.newlineBefore {
                advance()
                e = Expr(kind: .forceUnwrap(e), line: e.line, col: e.col)
            } else if isPunct("("), !cur.newlineBefore {
                advance()
                var args: [Arg] = []
                let saved = noTrailing; noTrailing = false
                while !isPunct(")") {
                    var label: String?
                    if let l = labelWord(cur), case .punct(":") = peek().tok { label = l; advance(); advance() }
                    args.append(Arg(label: label, value: try parseExpr()))
                    if !eatPunct(",") { break }
                }
                noTrailing = saved
                try expectPunct(")")
                e = Expr(kind: .call(e, args), line: e.line, col: e.col)
            } else if isPunct("["), !cur.newlineBefore {
                advance()
                let saved = noTrailing; noTrailing = false
                let idx = try parseExpr()
                if eatPunct(",") {
                    guard labelWord(cur) == "default", case .punct(":") = peek().tok else { throw err("a subscript takes one index, or `key, default: value` for a dictionary") }
                    advance(); advance()
                    let def = try parseExpr()
                    noTrailing = saved
                    try expectPunct("]")
                    e = Expr(kind: .dictSubscriptDefault(e, idx, def), line: e.line, col: e.col)
                    continue
                }
                noTrailing = saved
                try expectPunct("]")
                e = Expr(kind: .subscripted(e, idx), line: e.line, col: e.col)
            } else if isPunct("{"), !cur.newlineBefore, !noTrailing, canTakeTrailingClosure(e) {
                let closure = try parseClosure()
                if case .call(let callee, var args) = e.kind { args.append(Arg(label: nil, value: closure)); e = Expr(kind: .call(callee, args), line: e.line, col: e.col) }
                else { e = Expr(kind: .call(e, [Arg(label: nil, value: closure)]), line: e.line, col: e.col) }
            } else { return e }
        }
    }

    // MARK: Closures

    /// Whether the tokens after `{` are a closure signature (`x, y in`, `(a: Int) -> Int in`).
    // Scans ahead without consuming anything. It's a signature only if we reach `in` while
    // seeing nothing but names, types and brackets; any other token means the braces are a plain
    // closure body.
    private func startsClosureSignature() -> Bool {
        var i = p + 1, depth = 0
        if case .punct("[") = toks[i].tok { // capture list
            var d = 0
            repeat {
                if case .punct("[") = toks[i].tok { d += 1 } else if case .punct("]") = toks[i].tok { d -= 1 }
                i += 1
            } while d > 0 && i < toks.count
        }
        while i < toks.count {
            switch toks[i].tok {
            case .keyword("in"): return true
            case .ident, .op("->"), .op("?"), .op("<"), .op(">"), .punct(","), .punct(":"), .punct("."), .keyword("inout"), .keyword("Self"): break
            case .punct("("), .punct("["): depth += 1
            case .punct(")"), .punct("]"): depth -= 1; if depth < 0 { return false }
            default: return false
            }
            i += 1
        }
        return false
    }

    private mutating func parseClosure() throws -> Expr {
        let start = cur
        let signature = startsClosureSignature()   // looks ahead from the `{`
        try expectPunct("{")
        var params: [(name: String, type: TypeExpr?)] = []
        var ret: TypeExpr?
        var hasSig = false
        if signature {
            hasSig = true
            if isPunct("[") { try skipBalanced("[", "]") }
            if eatPunct("(") {
                while !isPunct(")") {
                    let n = try ident("a parameter name")
                    var t: TypeExpr?
                    if eatPunct(":") { t = try parseType() }
                    params.append((n, t))
                    if !eatPunct(",") { break }
                }
                try expectPunct(")")
            } else {
                while !isKw("in") && !isOp("->") {
                    let n = try ident("a parameter name")
                    var t: TypeExpr?
                    if eatPunct(":") { t = try parseType() }
                    params.append((n, t))
                    if !eatPunct(",") { break }
                }
            }
            if eatOp("->") { ret = try parseType() }
            guard eatKw("in") else { throw err("expected 'in'") }
        }
        shorthandStack.append(0)
        let saved = noTrailing; noTrailing = false
        let body = try parseStmtsUntilBrace()
        noTrailing = saved
        let maxSh = shorthandStack.removeLast()
        try expectPunct("}")
        return Expr(kind: .closure(Closure(params: params, ret: ret, body: body, hasSignature: hasSig, maxShorthand: maxSh)), line: start.line, col: start.col)
    }

    // MARK: Primary

    private mutating func parsePrimary() throws -> Expr {
        let t = cur
        func mk(_ k: Expr.Kind) -> Expr { Expr(kind: k, line: t.line, col: t.col) }
        switch t.tok {
        case .int(let v): advance(); return mk(.int(v))
        case .double(let v): advance(); return mk(.double(v))
        case .keyword("true"): advance(); return mk(.bool(true))
        case .keyword("false"): advance(); return mk(.bool(false))
        case .keyword("nil"): advance(); return mk(.nilLit)
        case .keyword("self"): advance(); return mk(.selfRef)
        case .keyword("Self"): advance(); return mk(.ident("Self"))
        case .ident(let n):
            advance()
            // Stack<Int>(...), an explicit specialisation of a generic type
            if isOp("<"), !cur.spaceBefore, n.first?.isUppercase == true {
                let save = p
                advance()
                var args: [TypeExpr] = []
                var ok = true
                repeat {
                    if let a = try? parseType() { args.append(a) } else { ok = false; break }
                } while eatPunct(",")
                if ok {
                    if isOp(">>") { ok = false }
                    else if !eatOp(">") { ok = false }
                }
                if ok, isPunct("(") || isPunct(".") { return mk(.genericRef(n, args)) }
                p = save
            }
            if n.hasPrefix("$"), n.count > 1 {
                let rest = n.dropFirst()
                if let k = Int(rest) {
                    if !shorthandStack.isEmpty { shorthandStack[shorthandStack.count - 1] = max(shorthandStack[shorthandStack.count - 1], k + 1) }
                    return mk(.shorthand(k))
                }
                return mk(.binding(String(rest)))
            }
            return mk(.ident(n))
        case .string(let parts):
            advance()
            var out: [StrInterp] = []
            for part in parts {
                switch part {
                case .text(let s): out.append(StrInterp(text: s, expr: nil))
                case .interp(let inner):
                    var sub = SwiftParser(tokens: inner, file: file)
                    sub.shorthandStack = shorthandStack
                    let e = try sub.parseExpr()
                    guard case .eof = sub.cur.tok else { throw sub.err("unexpected text in string interpolation") }
                    if !shorthandStack.isEmpty { shorthandStack[shorthandStack.count - 1] = max(shorthandStack[shorthandStack.count - 1], sub.shorthandStack.last ?? 0) }
                    out.append(StrInterp(text: nil, expr: e))
                }
            }
            return mk(.string(out))
        case .punct("("):
            advance()
            var items: [(label: String?, value: Expr)] = []
            let saved = noTrailing; noTrailing = false
            while !isPunct(")") {
                var label: String?
                if let l = labelWord(cur), case .punct(":") = peek().tok { label = l; advance(); advance() }
                items.append((label, try parseExpr()))
                if !eatPunct(",") { break }
            }
            noTrailing = saved
            try expectPunct(")")
            if items.count == 1, items[0].label == nil { return items[0].value }
            return mk(.tupleLit(items))
        case .punct("."):
            advance()
            if case .keyword("init") = cur.tok { advance(); return mk(.implicitMember("init")) }
            return mk(.implicitMember(try ident("a member name")))
        case .punct("["):
            // `[Int](repeating: 0, count: 3)` or an array literal.
            let save = p
            advance()
            if let elem = try? parseType() {
                if isPunct("]"), { if case .punct("(") = peek().tok { return true }; return false }() {
                    advance()
                    return mk(.typeRef(.array(elem)))
                }
                if isPunct(":"), case .keyword = peek().tok {} else if isPunct(":") {
                    advance()
                    if let v = try? parseType(), isPunct("]"), { if case .punct("(") = peek().tok { return true }; return false }() {
                        advance()
                        return mk(.typeRef(.dict(elem, v)))
                    }
                }
            }
            p = save
            advance()
            if isPunct(":"), case .punct("]") = peek().tok {      // [:]
                advance(); advance()
                return mk(.dictLiteral([]))
            }
            var items: [Expr] = []
            var pairs: [(key: Expr, value: Expr)] = []
            let saved = noTrailing; noTrailing = false
            while !isPunct("]") {
                let first = try parseExpr()
                if eatPunct(":") { pairs.append((first, try parseExpr())) } else { items.append(first) }
                if !eatPunct(",") { break }
            }
            noTrailing = saved
            try expectPunct("]")
            if !pairs.isEmpty {
                if !items.isEmpty { throw err("mix of array and dictionary items") }
                return mk(.dictLiteral(pairs))
            }
            return mk(.arrayLiteral(items))
        case .punct("{"):
            return try parseClosure()
        case .punct("\\"):
            advance()
            try expectPunct(".")
            var name = ""
            if case .keyword("self") = cur.tok { advance(); name = "self" } else { name = try ident("a property name") }
            while isPunct("."), case .ident(let more) = peek().tok { advance(); advance(); name += "." + more }
            return mk(.keyPath(name))
        case .op(let o) where Self.precedence[o] != nil || o == "<":
            // An operator used as a function: reduce(0, +)
            guard case .punct(let next) = peek().tok, next == ")" || next == "," else { throw err("expected an expression", at: t) }
            advance()
            return mk(.opRef(o))
        case .keyword:
            if let e = unsupportedError(t) { throw e }
            throw err("unexpected '\(t.tok)'", at: t)
        default:
            throw err("expected an expression", at: t)
        }
    }
}
