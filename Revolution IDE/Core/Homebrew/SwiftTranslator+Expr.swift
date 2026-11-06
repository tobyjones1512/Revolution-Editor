import Foundation

nonisolated extension SwiftTranslator {
    // MARK: Coercion

    /// `e` as a value of exactly type `t`, promoting to an optional where Swift does.
    func coerce(_ e: Expr, to t: SType) throws -> String {
        let (c, ct) = try expr(e, t)
        if ct == t { return c }
        if case .optional(let inner) = t, ct == inner { return "((\(try ctype(t))){ 1, \(c) })" }
        if case .named(let pn) = t, let pt = types[pn], pt.isProtocol, case .named(let cn) = ct, let idx = protocolConformers[pn]?.firstIndex(of: cn) {
            return "((\(try ctype(t))){ .tag = \(idx), .u.v\(idx) = \(c) })"
        }
        if case .optional(let inner) = t, case .named(let pn) = inner, let pt = types[pn], pt.isProtocol, case .named(let cn) = ct, let idx = protocolConformers[pn]?.firstIndex(of: cn) {
            return "((\(try ctype(t))){ 1, (\(try ctype(inner))){ .tag = \(idx), .u.v\(idx) = \(c) } })"
        }
        if case .optional(let inner) = t, case .optional(let have) = ct, have != inner { _ = inner }
        at(e)
        var hint = ""
        if ct.isNumeric && t.isNumeric { hint = " (use \(t.name)(x))" }
        throw fail("cannot convert value of type '\(ct.name)' to expected type '\(t.name)'" + hint)
    }

    /// Strips an optional so a literal can take its type: `let x: Double? = 5`.
    func base(_ t: SType?) -> SType? {
        if case .optional(let i)? = t { return i }
        return t
    }

    func literalish(_ e: Expr) -> Bool {
        switch e.kind {
        case .int, .implicitMember, .nilLit: return true
        case .unary("-", let x): return literalish(x)
        case .binary(_, let a, let b): return literalish(a) && literalish(b)
        default: return false
        }
    }

    // MARK: Expressions

    func expr(_ e: Expr, _ expected: SType?) throws -> (String, SType) {
        at(e)
        switch e.kind {
        case .int(let v):
            switch base(expected) {
            case .double?: return ("\(v).0", .double)
            case .float?: return ("\(v).0f", .float)
            case .uint32?: return ("\(v)u", .uint32)
            case .uint8?: return ("\(v)", .uint8)
            default: return ("\(v)", .int)
            }
        case .double(let v):
            if base(expected) == .float { return ("\(v)f", .float) }
            return ("\(v)", .double)
        case .bool(let b): return (b ? "1" : "0", .bool)
        case .nilLit:
            guard let exp = expected, case .optional = exp else { throw fail("'nil' needs a type to give it: write it where an optional is expected") }
            return ("((\(try ctype(exp))){0})", exp)
        case .string(let parts): return try stringExpr(parts)
        case .ident(let n): return try identExpr(n)
        case .selfRef:
            guard let ti = ctx.selfType else { throw fail("'self' is only available inside a type's method") }
            useSelf()
            return ti.isClass ? ("self", .named(ti.name)) : ("(*self)", .named(ti.name))
        case .shorthand(let k):
            guard let l = lookupLocal("$\(k)") else { throw fail("$\(k) can only be used inside a closure") }
            return (l.c, l.type)
        case .binding(let n):
            let (lc, lt) = try lvalue(Expr(kind: .ident(n), line: e.line, col: e.col))
            return ("&\(lc)", .binding(lt))
        case .member(let b, let name, let opt): return try memberExpr(b, name, optional: opt, e)
        case .implicitMember(let name): return try implicitMemberExpr(name, expected)
        case .tupleIndex(let b, let i):
            let (bc, bt) = try expr(b, nil)
            guard case .tuple(let es, _) = bt, i < es.count else { throw fail("value of type '\(bt.name)' has no element \(i)") }
            return ("\(bc).f\(i)", es[i])
        case .call(let callee, let args): return try callExpr(callee, args, e, expected)
        case .dictSubscriptDefault(let b, let key, let def):
            let (bc, bt) = try expr(b, nil)
            guard case .dict(let kt, let vt) = bt else { throw fail("only a dictionary takes a default: subscript") }
            let d = newTmp("d"), i = newTmp("i")
            return ("({ \(try ctype(bt)) \(d) = \(bc); int \(i) = \(bt.mangled)_find(&\(d), \(try coerce(key, to: kt))); \(i) >= 0 ? \(d).v[\(i)] : (\(try coerce(def, to: vt))); })", vt)
        case .subscripted(let b, let idx):
            let (bc, bt) = try expr(b, nil)
            if case .dict(let kt, let vt) = bt {
                let opt = SType.optional(vt)
                let d = newTmp("d"), i = newTmp("i")
                return ("({ \(try ctype(bt)) \(d) = \(bc); \(try ctype(opt)) _r = {0}; int \(i) = \(bt.mangled)_find(&\(d), \(try coerce(idx, to: kt))); if (\(i) >= 0) { _r.has = 1; _r.v = \(d).v[\(i)]; } _r; })", opt)
            }
            guard case .array(let elem) = bt else { throw fail("cannot subscript a value of type '\(bt.name)'") }
            let a = newTmp("a")
            return ("({ \(try ctype(bt)) \(a) = \(bc); \(a).a[ws_idx(\(try coerce(idx, to: .int)), \(a).n)]; })", elem)
        case .unary(let op, let x):
            let (c, t) = try expr(x, expected)
            switch op {
            case "-": guard t.isNumeric else { throw fail("operator '-' can't be applied to \(t.name)") }; return ("(-\(c))", t)
            case "!": guard t == .bool else { throw fail("operator '!' needs a Bool, not \(t.name)") }; return ("(!\(c))", .bool)
            default: guard t.isInteger else { throw fail("operator '~' needs an integer") }; return ("(~\(c))", t)
            }
        case .binary(let op, let l, let r): return try binaryExpr(op, l, r, e, expected)
        case .ternary(let c, let a, let b):
            let cc = try coerce(c, to: .bool)
            let (ac, at_) = try expr(a, expected)
            let bc = try coerce(b, to: at_)
            return ("(\(cc) ? \(ac) : \(bc))", at_)
        case .range: throw fail("a range can only be used in a for loop or a switch case")
        case .arrayLiteral(let items): return try arrayLiteralExpr(items, expected)
        case .dictLiteral(let pairs): return try dictLiteralExpr(pairs, expected)
        case .letPattern: throw fail("'let' patterns only work in a switch case or `if case`")
        case .tupleLit(let items): return try tupleLiteralExpr(items, expected)
        case .forceUnwrap(let x):
            let (c, t) = try expr(x, nil)
            guard case .optional(let inner) = t else { throw fail("cannot force unwrap a value of type '\(t.name)' that isn't optional") }
            let o = newTmp("o")
            return ("({ \(try ctype(t)) \(o) = \(c); if (!\(o).has) ws_fatal(); \(o).v; })", inner)
        case .closure(let c):
            if let exp = expected, case .fn(let ps, let r) = exp { return (try liftClosure(c, ps, r, expected: exp), exp) }
            // A closure with a full signature stands alone.
            if c.hasSignature, c.params.allSatisfy({ $0.type != nil }), let rt = c.ret {
                let ps = try c.params.map { try resolve($0.type!) }, r = try resolve(rt)
                let ft = SType.fn(ps, r)
                return (try liftClosure(c, ps, r, expected: ft), ft)
            }
            throw fail("a closure needs a type here: write its parameter and result types, like { (x: Int) -> Int in ... }")
        case .inoutRef: throw fail("'&' can only be used on an argument for an inout parameter")
        case .typeRef, .genericRef: throw fail("a type can't be used as a value here")
        case .keyPath: throw fail("key paths aren't supported")
        case .opRef: throw fail("an operator can only be passed to a function that takes one")
        }
    }

    // MARK: Strings

    func stringExpr(_ parts: [StrInterp]) throws -> (String, SType) {
        var acc: String?
        for part in parts {
            var piece: String
            if let t = part.text {
                piece = "ws_lit(\(UICodegen.cString(t, limit: 127)))"
            } else if let ie = part.expr {
                let (c, t) = try expr(ie, nil)
                at(ie)
                piece = try stringify(c, t)
            } else { continue }
            acc = acc.map { "ws_join(\($0), \(piece))" } ?? piece
        }
        return (acc ?? "ws_lit(\"\")", .string)
    }

    /// A `wn_str` for any printable value.
    func stringify(_ c: String, _ t: SType) throws -> String {
        switch t {
        case .string: return c
        case .int, .uint32, .uint8, .double, .float: return "ws_num((double)(\(c)))"
        case .bool: return "ws_lit((\(c)) ? \"true\" : \"false\")"
        case .optional(let inner):
            let o = newTmp("o")
            return "({ \(try ctype(t)) \(o) = \(c); \(o).has ? \(try stringify("\(o).v", inner)) : ws_lit(\"nil\"); })"
        case .named(let n):
            if let ti = types[n], ti.kind == .enumType {
                let v = newTmp("e")
                return "({ T_\(n) \(v) = \(c); wn_str _r = ws_lit(\"?\"); switch (\(v)\(ti.hasPayload ? ".tag" : "")) { " + ti.cases.map { "case T_\(n)_\($0): _r = ws_lit(\"\($0)\"); break;" }.joined(separator: " ") + " } _r; })"
            }
            throw fail("can't put a \(t.name) in a string")
        default: throw fail("can't put a \(t.name) in a string")
        }
    }

    // MARK: Identifiers and members

    func identExpr(_ n: String) throws -> (String, SType) {
        if let l = lookupLocal(n) { return (l.c, l.type) }
        if let ti = ctx.selfType, let p = ti.props.first(where: { $0.name == n }) {
            if !(ctx.isStatic || p.decl.isStatic) { useSelf() }
            return try propertyAccess(ti, p, base: ctx.isStatic || p.decl.isStatic ? nil : "self", baseIsPointer: true)
        }
        if let g = globals[n] { return (g.c, g.type) }
        if types[n] != nil { throw fail("'\(n)' is a type; use it with a member or call, like \(n)(...)") }
        throw fail("cannot find '\(n)' in scope")
    }

    /// Reads property `p` of `ti`. `base` is a C expression for the instance (nil for statics);
    /// `baseIsPointer` says whether it already is a pointer (as `self` is).
    func propertyAccess(_ ti: TypeInfo, _ p: PropInfo, base: String?, baseIsPointer: Bool) throws -> (String, SType) {
        let prefix = ti.isClass ? "C_" : "T_"
        if p.decl.isStatic {
            if p.isComputed { return ("\(prefix)\(ti.name)_get_\(p.name)()", p.type) }
            return ("\(prefix)\(ti.name)_\(p.name)", p.type)
        }
        guard let b = base else { throw fail("instance member '\(p.name)' can't be used from a static context") }
        if p.isComputed {
            let recv = ti.isClass || baseIsPointer ? b : "&\(b)"
            return ("\(prefix)\(ti.name)_get_\(p.name)(\(recv))", p.type)
        }
        let access = (ti.isClass || baseIsPointer) ? "\(b)->\(cname(p.name))" : "\(b).\(cname(p.name))"
        return (p.isBinding ? "(*\(access))" : access, p.type)
    }

    func staticTypeName(_ b: Expr) -> String? {
        if case .genericRef(let n, let targs) = b.kind, let d = genericTypes[n], let args = try? targs.map(resolve), args.count == d.generics.count,
           case .named(let key)? = try? instantiateType(d, args) { return key }
        guard case .ident(let n) = b.kind, lookupLocal(n) == nil else { return nil }
        if n == "Self", let st = ctx.selfType { return st.name }
        if let ti = ctx.selfType, ti.props.contains(where: { $0.name == n }) { return nil }
        if globals[n] != nil { return nil }
        return n
    }

    func memberExpr(_ b: Expr, _ name: String, optional: Bool, _ whole: Expr) throws -> (String, SType) {
        // $model.value: a binding to a property of an object
        if case .binding(let n) = b.kind {
            let inner = Expr(kind: .member(Expr(kind: .ident(n), line: b.line, col: b.col), name, optional: false), line: b.line, col: b.col)
            let (lc, lt) = try lvalue(inner)
            return ("&\(lc)", .binding(lt))
        }
        if !optional, let tn = staticTypeName(b) {
            if let r = try staticMember(tn, name) { return r }
        }
        let (bc, bt) = try expr(b, nil)
        if optional {
            guard case .optional(let inner) = bt else { throw fail("'?.' needs an optional value, but this is \(bt.name)") }
            let (mc, mt) = try instanceMember("_ov.v", inner, name, whole: whole, isLvalue: false)
            let resultType: SType = { if case .optional = mt { return mt }; return .optional(mt) }()
            let o = newTmp("o"), r = newTmp("r")
            var assign = "\(r).has = 1; \(r).v = \(mc.replacingOccurrences(of: "_ov", with: o));"
            if case .optional = mt { assign = "\(r) = \(mc.replacingOccurrences(of: "_ov", with: o));" }
            return ("({ \(try ctype(bt)) \(o) = \(bc); \(try ctype(resultType)) \(r) = {0}; if (\(o).has) { \(assign) } \(r); })", resultType)
        }
        if let lv = try? lvalue(b) { return try instanceMember(lv.0, bt, name, whole: whole, isLvalue: true) }
        return try instanceMember(bc, bt, name, whole: whole, isLvalue: false)
    }

    /// `base.name` where `base` is a value of type `bt`.
    func instanceMember(_ bc: String, _ bt: SType, _ name: String, whole: Expr, isLvalue: Bool) throws -> (String, SType) {
        switch bt {
        case .array: if let r = try arrayProperty(bc, bt, name) { return r }
        case .dict: if let r = try dictProperty(bc, bt, name) { return r }
        case .string: if let r = try stringProperty(bc, name) { return r }
        case .tuple(let es, let labels):
            if let i = labels.firstIndex(where: { $0 == name }) { return ("\(bc).f\(i)", es[i]) }
        case .optional: break
        case .double, .float, .int:
            if name == "magnitude" { return ("ws_dabs(\(bc))", bt) }
        default: break
        }
        guard let ti = info(bt) else { throw fail("value of type '\(bt.name)' has no member '\(name)'") }
        if ti.isProtocol { return try protocolProperty(bc, ti, name) }
        if ti.kind == .enumType {
            if name == "rawValue", let raw = ti.rawType { return ("T_\(ti.name)_rawValue(\(bc))", raw) }
        }
        guard let p = ti.props.first(where: { $0.name == name }) else { throw fail("'\(ti.name)' has no member '\(name)'") }
        if p.decl.isStatic { throw fail("'\(name)' is a static member; use \(ti.name).\(name)") }
        if ti.isClass { return try propertyAccess(ti, p, base: bc, baseIsPointer: true) }
        if p.isComputed {
            if isLvalue { return try propertyAccess(ti, p, base: bc, baseIsPointer: false) }
            let t = newTmp("t")
            return ("({ T_\(ti.name) \(t) = \(bc); T_\(ti.name)_get_\(p.name)(&\(t)); })", p.type)
        }
        return try propertyAccess(ti, p, base: bc, baseIsPointer: false)
    }

    /// `Type.member`: enum cases, static properties, constants.
    func staticMember(_ tn: String, _ name: String) throws -> (String, SType)? {
        if tn == "UI" {
            guard widgets.contains(name) else {
                throw fail("the UI has no widget named '\(name)'" + (widgets.isEmpty ? " (there's no .wiiui design in this project)" : "; widgets are: " + widgets.sorted().joined(separator: ", ")))
            }
            return ("UI_\(name.uppercased())", .int)
        }
        if tn == "Sprite" || tn == "Sound" || tn == "Music" {
            let names = tn == "Sprite" ? sprites : (tn == "Sound" ? sounds : musics)
            guard names.contains(name) else {
                throw fail("the project has no \(tn == "Music" ? "music (.brstm)" : tn.lowercased()) named '\(name)' in its assets folder" + (names.isEmpty ? "" : "; available: " + names.sorted().joined(separator: ", ")))
            }
            return ("\(tn.uppercased())_\(name.uppercased())", .int)
        }
        if tn == "Button", types["Button"] == nil {
            let buttons = ["a": "WPAD_BUTTON_A", "b": "WPAD_BUTTON_B", "one": "WPAD_BUTTON_1", "two": "WPAD_BUTTON_2", "plus": "WPAD_BUTTON_PLUS", "minus": "WPAD_BUTTON_MINUS",
                           "up": "WPAD_BUTTON_UP", "down": "WPAD_BUTTON_DOWN", "left": "WPAD_BUTTON_LEFT", "right": "WPAD_BUTTON_RIGHT"]
            guard let m = buttons[name] else { throw fail("Button has no '\(name)'; use a, b, one, two, plus, minus, up, down, left, right") }
            return (m, .uint32)
        }
        switch (tn, name) {
        case ("Int", "max"): return ("2147483647", .int)
        case ("Int", "min"): return ("(-2147483647 - 1)", .int)
        case ("UInt32", "max"): return ("4294967295u", .uint32)
        case ("UInt8", "max"): return ("255", .uint8)
        case ("Double", "pi"), ("Float", "pi"): return ("3.14159265358979323846", tn == "Float" ? .float : .double)
        case ("Double", "infinity"): return ("(1.0 / 0.0)", .double)
        default: break
        }
        guard let ti = types[tn] else { return nil }
        if ti.kind == .enumType {
            if ti.cases.contains(name) {
                if ti.hasPayload {
                    if let pl = ti.casePayloads[name], !pl.isEmpty { throw fail("'\(name)' carries values: write \(tn).\(name)(...)") }
                    return ("((T_\(tn)){ .tag = T_\(tn)_\(name) })", .named(tn))
                }
                return ("T_\(tn)_\(name)", .named(tn))
            }
            if name == "allCases" {
                let arr = SType.array(.named(tn))
                let elems = ti.cases.map { "T_\(tn)_\($0)" }.joined(separator: ", ")
                return ("((\(try ctype(arr))){ .a = { \(elems) }, .n = \(ti.cases.count) })", arr)
            }
        }
        if let p = ti.props.first(where: { $0.name == name && $0.decl.isStatic }) { return try propertyAccess(ti, p, base: nil, baseIsPointer: false) }
        throw fail("'\(tn)' has no static member '\(name)'")
    }

    /// `.name` where the type comes from context: an enum case or a static member of the expected type.
    func implicitMemberExpr(_ name: String, _ expected: SType?) throws -> (String, SType) {
        guard let exp = base(expected) else { throw fail("cannot infer the type of '.\(name)'; write it as Type.\(name)") }
        if exp == .double || exp == .float, let r = try staticMember("Double", name) { return r }
        guard case .named(let tn) = exp, types[tn] != nil else { throw fail("cannot infer a member '.\(name)' of \(exp.name)") }
        if let r = try staticMember(tn, name) { return r }
        throw fail("'\(tn)' has no member '\(name)'")
    }

    // MARK: Binary operators

    func binaryExpr(_ op: String, _ l: Expr, _ r: Expr, _ whole: Expr, _ expected: SType?) throws -> (String, SType) {
        if op == "&&" || op == "||" {
            return ("(\(try coerce(l, to: .bool)) \(op) \(try coerce(r, to: .bool)))", .bool)
        }
        if op == "??" {
            let (lc, lt) = try expr(l, nil)
            guard case .optional(let inner) = lt else { throw fail("the left side of '??' must be optional, not \(lt.name)") }
            let o = newTmp("o")
            // `a ?? b` where b is itself optional gives an optional.
            let (rc, rt) = try expr(r, inner)
            if rt == inner { return ("({ \(try ctype(lt)) \(o) = \(lc); \(o).has ? \(o).v : (\(rc)); })", inner) }
            if rt == lt { return ("({ \(try ctype(lt)) \(o) = \(lc); \(o).has ? \(o) : (\(rc)); })", lt) }
            throw fail("cannot convert \(rt.name) to \(inner.name) for '??'")
        }
        let comparison = ["==", "!=", "<", ">", "<=", ">="].contains(op)
        let outer: SType? = comparison ? nil : expected
        var lc: String, lt: SType, rc: String, rt: SType
        if literalish(l), !literalish(r) {
            (rc, rt) = try expr(r, outer)
            (lc, lt) = try expr(l, rt)
        } else {
            (lc, lt) = try expr(l, outer)
            (rc, rt) = try expr(r, lt)
        }
        at(whole)
        // Comparisons with nil, and optional against a value.
        if comparison, op == "==" || op == "!=" {
            if case .nilLit = r.kind, case .optional = lt { return (op == "==" ? "(!\(lc).has)" : "(\(lc).has)", .bool) }
            if case .nilLit = l.kind, case .optional = rt { return (op == "==" ? "(!\(rc).has)" : "(\(rc).has)", .bool) }
            if case .optional(let inner) = lt, rt == inner {
                let o = newTmp("o")
                let eq = try equalityCode("\(o).v", rc, inner)
                return ("({ \(try ctype(lt)) \(o) = \(lc); \(op == "==" ? "" : "!")(\(o).has && \(eq)); })", .bool)
            }
        }
        if lt != rt {
            if case .optional(let inner) = rt, lt == inner, comparison { throw fail("cannot compare \(lt.name) with \(rt.name)") }
            throw fail("binary operator '\(op)' cannot be applied to operands of type '\(lt.name)' and '\(rt.name)'" + (lt.isNumeric && rt.isNumeric ? " (convert one with Int(x) or Double(x))" : ""))
        }
        if comparison {
            if op == "==" || op == "!=" {
                let eq = try equalityCode(lc, rc, lt)
                return (op == "==" ? "(\(eq))" : "(!(\(eq)))", .bool)
            }
            if lt == .string { return ("(strcmp(\(lc).s, \(rc).s) \(op) 0)", .bool) }
            guard lt.isNumeric else { throw fail("operator '\(op)' can't be applied to \(lt.name)") }
            return ("(\(lc) \(op) \(rc))", .bool)
        }
        return (try binaryCode(op, lc, lt, rc, lt), lt)
    }

    /// C text for an `==` between two values of type `t`.
    func equalityCode(_ a: String, _ b: String, _ t: SType) throws -> String {
        switch t {
        case .string: return "ws_eq(\(a), \(b))"
        case .int, .uint32, .uint8, .double, .float, .bool: return "(\(a)) == (\(b))"
        case .named(let n):
            if let ti = types[n], ti.kind == .enumType, ti.hasPayload { throw fail("enums with values can't be compared with ==; use a switch or `if case`") }
            if let ti = types[n], ti.kind == .enumType { return "(\(a)) == (\(b))" }
            if let ti = types[n], ti.isClass { return "(\(a)) == (\(b))" }
            if let ti = types[n], ti.kind == .structType {
                let x = newTmp("x"), y = newTmp("y")
                var parts: [String] = []
                for p in ti.storedProps {
                    if p.isBinding { continue }
                    parts.append(try equalityCode("\(x).\(cname(p.name))", "\(y).\(cname(p.name))", p.type))
                }
                return "({ T_\(n) \(x) = \(a), \(y) = \(b); \(parts.isEmpty ? "1" : parts.map { "(\($0))" }.joined(separator: " && ")); })"
            }
            throw fail("'\(n)' can't be compared with ==")
        case .array(let elem):
            let x = newTmp("x"), y = newTmp("y"), i = newTmp("i"), eq = newTmp("eq")
            let one = try equalityCode("\(x).a[\(i)]", "\(y).a[\(i)]", elem)
            return "({ \(try ctype(t)) \(x) = \(a), \(y) = \(b); int \(eq) = \(x).n == \(y).n; for (int \(i) = 0; \(i) < \(x).n && \(eq); \(i)++) if (!(\(one))) \(eq) = 0; \(eq); })"
        case .optional(let inner):
            let x = newTmp("x"), y = newTmp("y")
            return "({ \(try ctype(t)) \(x) = \(a), \(y) = \(b); (!\(x).has && !\(y).has) || (\(x).has && \(y).has && \(try equalityCode("\(x).v", "\(y).v", inner))); })"
        case .tuple(let es, _):
            let x = newTmp("x"), y = newTmp("y")
            let parts = try es.enumerated().map { try equalityCode("\(x).f\($0.offset)", "\(y).f\($0.offset)", $0.element) }
            return "({ \(try ctype(t)) \(x) = \(a), \(y) = \(b); \(parts.isEmpty ? "1" : parts.map { "(\($0))" }.joined(separator: " && ")); })"
        default: throw fail("values of type \(t.name) can't be compared with ==")
        }
    }

    func binaryCode(_ op: String, _ lc: String, _ lt: SType, _ rc: String, _ rt: SType) throws -> String {
        if lt == .string {
            guard op == "+" else { throw fail("operator '\(op)' can't be applied to String") }
            return "ws_join(\(lc), \(rc))"
        }
        if case .array = lt {
            guard op == "+" else { throw fail("operator '\(op)' can't be applied to \(lt.name)") }
            return try arrayConcat(lc, lt, rc)
        }
        guard lt.isNumeric else { throw fail("operator '\(op)' can't be applied to \(lt.name)") }
        if lt.isFloating, ["%", "&", "|", "^", "<<", ">>"].contains(op) { throw fail("operator '\(op)' needs integers") }
        if op == "/" && lt.isInteger { return "ws_idiv(\(lc), \(rc))" }
        if op == "%" { return "ws_imod(\(lc), \(rc))" }
        return "(\(lc) \(op) \(rc))"
    }

    // MARK: Literals

    func arrayLiteralExpr(_ items: [Expr], _ expected: SType?) throws -> (String, SType) {
        var elem: SType
        if case .array(let e)? = base(expected) { elem = e }
        else if let first = items.first { elem = try expr(first, nil).1 }
        else { throw fail("an empty array needs a type: write [Int]() or give it a type") }
        let cs = try items.map { try coerce($0, to: elem) }
        let arr = SType.array(elem)
        if cs.count > capacity(elem) { throw fail("an array of \(elem.name) holds at most \(capacity(elem)) items") }
        if cs.isEmpty { return ("((\(try ctype(arr))){0})", arr) }
        return ("((\(try ctype(arr))){ .a = { \(cs.joined(separator: ", ")) }, .n = \(cs.count) })", arr)
    }

    func dictLiteralExpr(_ pairs: [(key: Expr, value: Expr)], _ expected: SType?) throws -> (String, SType) {
        var kt: SType, vt: SType
        if case .dict(let k, let v)? = base(expected) { kt = k; vt = v }
        else if let first = pairs.first { kt = try expr(first.key, nil).1; vt = try expr(first.value, nil).1 }
        else { throw fail("an empty dictionary needs a type: write [String: Int]() or give it a type") }
        let dt = SType.dict(kt, vt)
        let dc = try ctype(dt)
        if pairs.isEmpty { return ("((\(dc)){0})", dt) }
        let r = newTmp("d")
        var sets = ""
        for p in pairs { sets += "\(dt.mangled)_set(&\(r), \(try coerce(p.key, to: kt)), \(try coerce(p.value, to: vt))); " }
        return ("({ \(dc) \(r) = {0}; \(sets)\(r); })", dt)
    }

    func tupleLiteralExpr(_ items: [(label: String?, value: Expr)], _ expected: SType?) throws -> (String, SType) {
        if items.isEmpty { return ("((void)0)", .void) }
        var cs: [String] = [], ts: [SType] = []
        var expectedElems: [SType]?
        if case .tuple(let es, _)? = base(expected), es.count == items.count { expectedElems = es }
        for (i, item) in items.enumerated() {
            if let ee = expectedElems { cs.append(try coerce(item.value, to: ee[i])); ts.append(ee[i]) }
            else { let (c, t) = try expr(item.value, nil); cs.append(c); ts.append(t) }
        }
        let tt = SType.tuple(ts, items.map { $0.label })
        let fields = cs.enumerated().map { ".f\($0.offset) = \($0.element)" }.joined(separator: ", ")
        return ("((\(try ctype(tt))){ \(fields) })", tt)
    }
}


nonisolated extension SwiftTranslator {
    // MARK: Protocols (values of a protocol type)

    /// The requirement lists for `ti` and the protocols it inherits from.
    func protocolRequirements(_ ti: TypeInfo) -> (methods: [String: FuncInfo], props: [String: PropInfo]) {
        var methods: [String: FuncInfo] = [:], props: [String: PropInfo] = [:]
        var seen = Set<String>(), work = [ti.name]
        while let n = work.popLast() {
            guard seen.insert(n).inserted, let p = types[n], p.isProtocol else { continue }
            for (k, v) in p.methods { methods[k] = v }
            for pr in p.props { props[pr.name] = pr }
            work += p.conformances
        }
        return (methods, props)
    }

    func protocolProperty(_ bc: String, _ ti: TypeInfo, _ name: String) throws -> (String, SType) {
        guard let p = protocolRequirements(ti).props[name] else { throw fail("the protocol '\(ti.name)' has no property '\(name)'") }
        let conformers = protocolConformers[ti.name] ?? []
        let x = newTmp("x"), r = newTmp("r")
        var cases = ""
        for (i, cn) in conformers.enumerated() {
            let ci = types[cn]!
            guard let cp = ci.props.first(where: { $0.name == name }) else { continue }
            let (acc, _) = try propertyAccess(ci, cp, base: "\(x).u.v\(i)", baseIsPointer: false)
            cases += "case \(i): \(r) = \(acc); break; "
        }
        return ("({ \(try ctype(.named(ti.name))) \(x) = \(bc); \(try decl(p.type, r)) = {0}; switch (\(x).tag) { \(cases)} \(r); })", p.type)
    }

    func protocolCall(_ obj: Expr, _ oc: String, _ ti: TypeInfo, _ name: String, _ args: [Arg]) throws -> (String, SType) {
        guard let req = protocolRequirements(ti).methods[name] else { throw fail("the protocol '\(ti.name)' has no method '\(name)'") }
        if req.params.contains(where: { $0.isInout }) { throw fail("inout parameters in protocol methods aren't supported") }
        let conformers = protocolConformers[ti.name] ?? []
        let xt = try ctype(.named(ti.name))
        let x = newTmp("x")
        var setup = ""
        var argNames: [String] = []
        let given = try matchArguments(req.params, args, what: "'\(name)'")
        for (i, a) in given.enumerated() {
            let t = newTmp("a")
            setup += "\(try decl(req.params[i].type, t)) = \(a); "
            argNames.append(t)
        }
        let mutating = req.decl.isMutating
        var recv: String
        if mutating {
            try requireAssignable(obj)
            recv = "\(xt) *\(x) = &\(try lvalue(obj).0);"
        } else {
            recv = "\(xt) \(x)_v = \(oc); \(xt) *\(x) = &\(x)_v;"
        }
        let r = newTmp("r")
        var cases = ""
        for (i, cn) in conformers.enumerated() {
            let ci = types[cn]!
            guard let cm = ci.methods[name] else { continue }
            let selfArg = ci.isClass ? "\(x)->u.v\(i)" : "&\(x)->u.v\(i)"
            let call = "\(cm.cName)(\(([selfArg] + argNames).joined(separator: ", ")))"
            cases += "case \(i): " + (req.ret == .void ? "\(call);" : "\(r) = \(call);") + " break; "
        }
        if req.ret == .void { return ("({ \(recv) \(setup)switch (\(x)->tag) { \(cases)} })", .void) }
        return ("({ \(recv) \(setup)\(try decl(req.ret, r)) = {0}; switch (\(x)->tag) { \(cases)} \(r); })", req.ret)
    }

    // MARK: Enums with values

    /// `.circle(let r)` / `Shape.rect(let w, _)` as the case name and its sub-patterns.
    func casePattern(_ e: Expr) -> (name: String, args: [Arg]?)? {
        switch e.kind {
        case .implicitMember(let n): return (n, nil)
        case .member(_, let n, _): return (n, nil)
        case .call(let callee, let args):
            switch callee.kind {
            case .implicitMember(let n): return (n, args)
            case .member(_, let n, _): return (n, args)
            default: return nil
            }
        default: return nil
        }
    }

    func payloadConstructor(_ ti: TypeInfo, _ name: String, _ args: [Arg]) throws -> (String, SType) {
        let pl = ti.casePayloads[name] ?? []
        let params = pl.enumerated().map { ParamInfo(label: $0.element.label, name: "f\($0.offset)", type: $0.element.type, defaultValue: nil, isInout: false) }
        let a = try matchArguments(params, args, what: "'\(ti.name).\(name)'")
        let fields = a.isEmpty ? "" : ", .u.c_\(name) = { \(a.joined(separator: ", ")) }"
        return ("((T_\(ti.name)){ .tag = T_\(ti.name)_\(name)\(fields) })", .named(ti.name))
    }

    /// Declares the variables a pattern binds, from the enum value held in C variable `m`.
    func bindCasePattern(_ ti: TypeInfo, _ name: String, _ args: [Arg]?, value m: String, indent n: Int, into out: inout String) throws {
        let pl = ti.casePayloads[name] ?? []
        guard let args else { return }
        guard args.count == pl.count else { throw fail("the case '\(name)' has \(pl.count) value\(pl.count == 1 ? "" : "s"), but the pattern has \(args.count)") }
        for (i, a) in args.enumerated() {
            switch a.value.kind {
            case .letPattern(let v): try bind(.name(v), type: pl[i].type, value: "\(m).u.c_\(name).f\(i)", isLet: true, indent: n, into: &out)
            case .ident("_"): continue
            default: throw fail("a pattern can bind with `let name` or ignore a value with `_`")
            }
        }
    }

    func payloadSwitch(_ subject: String, _ ti: TypeInfo, _ cases: [(patterns: [Expr], body: [Stmt])], _ def: [Stmt]?, indent n: Int) throws -> String {
        let p = ind(n)
        let sv = newTmp("sv")
        var out = "\(p){\n\(p)    T_\(ti.name) \(sv) = \(subject);\n\(p)    switch (\(sv).tag) {\n"
        for c in cases {
            var parsed: [(name: String, args: [Arg]?)] = []
            for pat in c.patterns {
                guard let cp = casePattern(pat), ti.cases.contains(cp.name) else { at(pat); throw fail("expected a case of \(ti.name)") }
                parsed.append(cp)
            }
            let binds = parsed.contains { $0.args?.contains { if case .letPattern = $0.value.kind { return true }; return false } ?? false }
            if binds && parsed.count > 1 { throw fail("a case with several patterns can't bind values") }
            for cp in parsed { out += "\(p)    case T_\(ti.name)_\(cp.name):\n" }
            ctx.scopes.append([:])
            var bindCode = ""
            if let first = parsed.first { try bindCasePattern(ti, first.name, first.args, value: sv, indent: n + 2, into: &bindCode) }
            let body = try block(c.body, indent: n + 2)
            ctx.scopes.removeLast()
            out += "\(p)    {\n\(bindCode)\(body)\(p)        break;\n\(p)    }\n"
        }
        if let def { out += "\(p)    default:\n\(p)    {\n\(try block(def, indent: n + 2))\(p)        break;\n\(p)    }\n" }
        return out + "\(p)    }\n\(p)}\n"
    }
}
