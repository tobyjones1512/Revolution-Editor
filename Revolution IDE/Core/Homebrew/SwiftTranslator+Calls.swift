import Foundation

nonisolated extension SwiftTranslator {
    // MARK: Dispatch

    func callExpr(_ callee: Expr, _ args: [Arg], _ whole: Expr, _ expected: SType?) throws -> (String, SType) {
        switch callee.kind {
        case .ident(let name): return try identCall(name, args, whole, expected)
        case .member(let obj, let name, let optional): return try methodCall(obj, name, optional: optional, args, whole, expected)
        case .genericRef(let name, let targs):
            guard let d = genericTypes[name] else { throw fail("'\(name)' isn't a generic type") }
            return try genericInit(d, explicit: try targs.map(resolve), args, whole, expected)
        case .implicitMember(let name):
            guard let exp = base(expected), case .named(let tn) = exp, let ti = types[tn], ti.kind == .enumType, ti.cases.contains(name), ti.hasPayload else {
                throw fail("cannot infer the type of '.\(name)(...)'; write it as Type.\(name)(...)")
            }
            return try payloadConstructor(ti, name, args)
        case .typeRef(.array(let te)): return try arrayConstruct(.array(try resolve(te)), args)
        case .typeRef(.dict(let kt, let vt)):
            let dt = SType.dict(try resolve(kt), try resolve(vt))
            guard args.isEmpty else { throw fail("a dictionary is created empty: [K: V]()") }
            return ("((\(try ctype(dt))){0})", dt)
        default:
            let (fc, ft) = try expr(callee, nil)
            guard case .fn(let ps, let r) = ft else { throw fail("a value of type '\(ft.name)' can't be called") }
            return try callFunctionValue(fc, ps, r, args)
        }
    }

    func identCall(_ name: String, _ args: [Arg], _ whole: Expr, _ expected: SType?) throws -> (String, SType) {
        if let l = lookupLocal(name), case .fn(let ps, let r) = l.type { return try callFunctionValue(l.c, ps, r, args) }
        if let f = ctx.localFuncs[name] { return try userCall(f, args, selfArg: nil) }
        if let ti = ctx.selfType, let m = ti.methods[name] {
            if m.isStatic { return try userCall(m, args, selfArg: nil) }
            if ctx.isStatic { throw fail("instance method '\(name)' can't be used from a static context") }
            useSelf()
            return try userCall(m, args, selfArg: "self")
        }
        if let g = genericFuncs[name] {
            let params = g.params.map { (label: $0.label, type: $0.type, isInout: $0.isInout) }
            let b = try inferGenerics(g.generics, params: params, ret: g.ret, args: args, expected: expected, owner: nil)
            return try userCall(try instantiateFunc(g, b), args, selfArg: nil)
        }
        if let f = funcs[name] { return try userCall(f, args, selfArg: nil) }
        if let ti = types[name] { return try typeInit(ti, args, whole) }
        if let d = genericTypes[name] { return try genericInit(d, explicit: nil, args, whole, expected) }
        if let r = try conversion(name, args) { return r }
        if let r = try numericBuiltin(name, args) { return r }
        if let r = try specialCall(name, args, expected) { return r }
        if usesView, let r = try viewCall(name, args, whole) { return r }
        if let b = builtinFunctions[name] { return try builtinCall(name, b, args) }
        throw fail("cannot find '\(name)' in scope")
    }

    // MARK: User functions

    /// Matches `given` against `params` in order, using defaults for what's left out. Returns C
    /// text for each parameter.
    func matchArguments(_ params: [ParamInfo], _ given: [Arg], what: String) throws -> [String] {
        var out: [String] = []
        var k = 0
        for p in params {
            if k < given.count, given[k].label == p.label {
                let a = given[k].value
                if p.isInout {
                    guard case .inoutRef(let inner) = a.kind else { at(a); throw fail("pass '&' with the variable for the inout parameter '\(p.name)'") }
                    try requireAssignable(inner)
                    let (lc, lt) = try lvalue(inner)
                    guard lt == p.type else { at(a); throw fail("cannot pass \(lt.name) as an inout \(p.type.name)") }
                    out.append("&\(lc)")
                } else {
                    if case .inoutRef = a.kind { at(a); throw fail("'&' can only be used with an inout parameter") }
                    out.append(try argument(a, to: p.type))
                }
                k += 1
            } else if let d = p.defaultValue {
                out.append(try coerce(d, to: p.type))
            } else {
                if k < given.count { at(given[k].value) }
                throw fail(p.label == nil ? "\(what) takes an unlabeled argument here" : "\(what) expects the label '\(p.label!):' here")
            }
        }
        if k < given.count { at(given[k].value); throw fail("extra argument in call to \(what)") }
        return out
    }

    /// An argument for a parameter of type `t`: closures are turned into function values.
    func argument(_ a: Expr, to t: SType) throws -> String {
        if case .fn(let ps, let r) = t { return try functionValue(a, ps, r, byReference: true) }
        return try coerce(a, to: t)
    }

    func userCall(_ f: FuncInfo, _ args: [Arg], selfArg: String?) throws -> (String, SType) {
        let a = try matchArguments(f.params, args, what: "'\(f.decl.name)'")
        let all = (selfArg.map { [$0] } ?? []) + a
        return ("\(f.cName)(\(all.joined(separator: ", ")))", f.ret)
    }

    // MARK: Methods

    func methodCall(_ obj: Expr, _ name: String, optional: Bool, _ args: [Arg], _ whole: Expr, _ expected: SType?) throws -> (String, SType) {
        if !optional, let tn = staticTypeName(obj) {
            if let r = try staticCall(tn, name, args, whole, expected) { return r }
        }
        // `.white.opacity(0.5)`: the leading `.white` takes its type from the context.
        var isImplicit = false
        if case .implicitMember = obj.kind { isImplicit = true }
        let (oc, ot) = try expr(obj, isImplicit ? expected : nil)
        if optional {
            guard case .optional(let inner) = ot else { throw fail("'?.' needs an optional value, but this is \(ot.name)") }
            let o = newTmp("o")
            let recv = Expr(kind: .ident("$opt"), line: obj.line, col: obj.col)
            ctx.scopes.append(["$opt": Local(type: inner, c: "\(o).v", isLet: false)])
            defer { ctx.scopes.removeLast() }
            let (cc, ct) = try methodCall(recv, name, optional: false, args, whole, expected)
            if ct == .void { return ("({ \(try ctype(ot)) \(o) = \(oc); if (\(o).has) { \(cc); } })", .void) }
            let resultType: SType = { if case .optional = ct { return ct }; return .optional(ct) }()
            let r = newTmp("r")
            let set = { if case .optional = ct { return "\(r) = \(cc);" }; return "\(r).has = 1; \(r).v = \(cc);" }()
            return ("({ \(try ctype(ot)) \(o) = \(oc); \(try ctype(resultType)) \(r) = {0}; if (\(o).has) { \(set) } \(r); })", resultType)
        }
        switch ot {
        case .array: if let r = try arrayCall(obj, oc, ot, name, args) { return r }
        case .dict: if let r = try dictCall(obj, oc, ot, name, args) { return r }
        case .string: if let r = try stringCall(oc, name, args) { return r }
        case .int, .uint32, .uint8, .double, .float: if let r = try numberCall(oc, ot, name, args) { return r }
        case .fn(let ps, let r) where name == "callAsFunction": return try callFunctionValue(oc, ps, r, args)
        default: break
        }
        guard let ti = info(ot) else { throw fail("value of type '\(ot.name)' has no method '\(name)'") }
        if ti.isProtocol { return try protocolCall(obj, oc, ti, name, args) }
        guard let m = ti.methods[name] else {
            // A closure stored in a property: obj.handler(x)
            if let p = ti.props.first(where: { $0.name == name }), case .fn(let ps, let r) = p.type {
                let (pc, _) = try instanceMember(oc, ot, name, whole: whole, isLvalue: true)
                return try callFunctionValue(pc, ps, r, args)
            }
            throw fail("'\(ti.name)' has no method '\(name)'")
        }
        if m.isStatic { throw fail("'\(name)' is a static method; call it as \(ti.name).\(name)(...)") }
        var selfArg: String
        if ti.isClass { selfArg = oc }
        else if let lv = try? lvalue(obj) {
            if m.decl.isMutating { try requireAssignable(obj) }
            selfArg = "&\(lv.0)"
        } else {
            if m.decl.isMutating { throw fail("cannot call the mutating method '\(name)' on a temporary value") }
            let t = newTmp("t")
            let (cc, ct) = try userCall(m, args, selfArg: "&\(t)")
            return ("({ \(try ctype(ot)) \(t) = \(oc); \(cc); })", ct)
        }
        return try userCall(m, args, selfArg: selfArg)
    }

    /// `Type.method(...)`
    func staticCall(_ tn: String, _ name: String, _ args: [Arg], _ whole: Expr, _ expected: SType?) throws -> (String, SType)? {
        switch (tn, name) {
        case ("Int", "random"), ("UInt32", "random"):
            guard args.count == 1, args[0].label == "in", case .range(let lo, let hi, let inclusive) = args[0].value.kind else { throw fail("use Int.random(in: 0..<10)") }
            let h = try coerce(hi, to: .int)
            return ("ws_random_int(\(try coerce(lo, to: .int)), \(inclusive ? h : "(\(h)) - 1"))", .int)
        case ("Double", "random"), ("Float", "random"):
            guard args.count == 1, args[0].label == "in", case .range(let lo, let hi, _) = args[0].value.kind else { throw fail("use Double.random(in: 0..<1)") }
            return ("ws_random_double(\(try coerce(lo, to: .double)), \(try coerce(hi, to: .double)))", .double)
        case ("Bool", "random"):
            return ("(rand() & 1)", .bool)
        default: break
        }
        guard let ti = types[tn] else { return nil }
        if ti.kind == .enumType, ti.hasPayload, ti.cases.contains(name) { return try payloadConstructor(ti, name, args) }
        if let m = ti.methods[name], m.isStatic { return try userCall(m, args, selfArg: nil) }
        // A static property holding a closure
        if let p = ti.props.first(where: { $0.name == name && $0.decl.isStatic }), case .fn(let ps, let r) = p.type {
            let (pc, _) = try propertyAccess(ti, p, base: nil, baseIsPointer: false)
            return try callFunctionValue(pc, ps, r, args)
        }
        if ti.methods[name] != nil || ti.props.contains(where: { $0.name == name }) { return nil }
        throw fail("'\(tn)' has no static method '\(name)'")
    }

    // MARK: Initialisers

    /// `Stack<Int>(...)` or `Stack(...)`: specialise the type, then build it.
    func genericInit(_ d: TypeDecl, explicit: [SType]?, _ args: [Arg], _ whole: Expr, _ expected: SType?) throws -> (String, SType) {
        var targs: [SType]
        if let e = explicit {
            guard e.count == d.generics.count else { throw fail("'\(d.name)' needs \(d.generics.count) type argument\(d.generics.count == 1 ? "" : "s")") }
            targs = e
        } else {
            var params: [(label: String?, type: TypeExpr, isInout: Bool)] = []
            if let i = d.inits.first { params = i.params.map { (label: $0.label, type: $0.type, isInout: $0.isInout) } }
            else { params = d.props.filter { !$0.isStatic && $0.getter == nil && !($0.isLet && $0.value != nil) && $0.type != nil }.map { (label: $0.name, type: $0.type!, isInout: false) } }
            let selfType: TypeExpr = .name(d.name, d.generics.map { .name($0, []) })
            let b = try inferGenerics(d.generics, params: params, ret: selfType, args: args, expected: expected, owner: d.name)
            targs = d.generics.map { b[$0]! }
        }
        let t = try instantiateType(d, targs)
        guard case .named(let key) = t, let ti = types[key] else { throw fail("couldn't specialise '\(d.name)'") }
        return try typeInit(ti, args, whole)
    }

    func typeInit(_ ti: TypeInfo, _ args: [Arg], _ whole: Expr) throws -> (String, SType) {
        let t = SType.named(ti.name)
        if ti.kind == .enumType {
            guard args.count == 1, args[0].label == "rawValue", let raw = ti.rawType else { throw fail("an enum can only be made with \(ti.name)(rawValue:) when it has a raw type") }
            try ensureEnumHelpers(ti)
            return ("T_\(ti.name)_fromRaw(\(try coerce(args[0].value, to: raw)))", .optional(t))
        }
        if let i = ti.inits.first {
            let a = try matchArguments(i.params, args, what: "'\(ti.name)'")
            return ("\(i.cName)(\(a.joined(separator: ", ")))", t)
        }
        if ti.isClass {
            guard args.isEmpty else { throw fail("'\(ti.name)' has no initialiser taking arguments; add an init") }
            let missing = ti.storedProps.filter { $0.decl.value == nil && !$0.isBinding }
            if !missing.isEmpty { throw fail("'\(ti.name)' needs an init: property '\(missing[0].name)' has no value") }
            return ("C_\(ti.name)_new()", t)
        }
        // Memberwise initialiser: arguments follow the property order; omitted ones use defaults.
        var provided: [String: String] = [:]
        var idx = 0
        let props = ti.storedProps.filter { !($0.decl.isLet && $0.decl.value != nil) }
        for g in args {
            guard idx < props.count else { throw fail("too many arguments to '\(ti.name)'") }
            // Skip properties with defaults that the caller left out.
            while idx < props.count, g.label != props[idx].name, props[idx].decl.value != nil || props[idx].isState { idx += 1 }
            guard idx < props.count else { throw fail("extra argument '\(g.label ?? "")' in call to '\(ti.name)'") }
            let p = props[idx]
            if g.label != p.name { at(g.value); throw fail("expected the label '\(p.name):' here (arguments follow the property order)") }
            if p.isBinding {
                guard case .binding = (try expr(g.value, .binding(p.type))).1 else { at(g.value); throw fail("'\(p.name)' needs a binding: pass $\(p.name) from a @State property") }
                provided[p.name] = try coerce(g.value, to: .binding(p.type))
            } else {
                provided[p.name] = try coerce(g.value, to: p.type)
            }
            idx += 1
        }
        var parts: [String] = []
        for p in ti.storedProps {
            if let v = provided[p.name] { parts.append(".\(cname(p.name)) = \(v)") }
            else if let d = p.decl.value { parts.append(".\(cname(p.name)) = \(try coerce(d, to: p.type))") }
            else if p.isBinding { throw fail("missing argument for binding '\(p.name)' in '\(ti.name)'") }
            else if case .optional = p.type { continue }
            else { throw fail("missing argument for property '\(p.name)' in '\(ti.name)'") }
        }
        return ("((T_\(ti.name)){ \(parts.joined(separator: ", ")) })", t)
    }

    /// `rawValue` and `init?(rawValue:)` for an enum with a raw type, emitted once on demand.
    func ensureEnumHelpers(_ ti: TypeInfo) throws {
        let key = "enumhelpers.\(ti.name)"
        if registered.contains(key) { return }
        registered.insert(key)
        guard let raw = ti.rawType else { return }
        let saved = (ctx, curFile, curLine, curCol)
        defer { (ctx, curFile, curLine, curCol) = saved }
        ctx = FnCtx()
        let n = ti.name, rc = try ctype(raw)
        var next = 0
        var rawCode: [String: String] = [:]
        for c in ti.decl.cases {
            if let v = ti.rawValues[c.name] {
                rawCode[c.name] = try coerce(v, to: raw)
                if case .int(let k) = v.kind { next = k + 1 }
            } else if raw == .string {
                rawCode[c.name] = "ws_lit(\"\(c.name)\")"
            } else {
                rawCode[c.name] = "\(next)"; next += 1
            }
        }
        let optType = try ctype(.optional(raw == .string ? .named(n) : .named(n)))
        var get = "static __attribute__((unused)) \(rc) T_\(n)_rawValue(T_\(n) v) { switch (v) { "
        var from = "static __attribute__((unused)) \(optType) T_\(n)_fromRaw(\(rc) r) { "
        for c in ti.cases {
            get += "case T_\(n)_\(c): return \(rawCode[c]!); "
            from += raw == .string ? "if (ws_eq(r, \(rawCode[c]!))) return (\(optType)){ 1, T_\(n)_\(c) }; " : "if (r == \(rawCode[c]!)) return (\(optType)){ 1, T_\(n)_\(c) }; "
        }
        get += "} return \(raw == .string ? "ws_lit(\"\")" : "0"); }"
        from += "return (\(optType)){0}; }"
        typeDefs.append(get)
        typeDefs.append(from)
    }

    // MARK: Conversions and specials

    func conversion(_ name: String, _ args: [Arg]) throws -> (String, SType)? {
        let targets: [String: SType] = ["Int": .int, "Int32": .int, "UInt32": .uint32, "UInt": .uint32, "UInt8": .uint8, "Double": .double, "Float": .float, "CGFloat": .double, "String": .string, "Bool": .bool]
        guard let target = targets[name] else { return nil }
        guard args.count == 1, args[0].label == nil else { throw fail("\(name)() takes one unlabeled argument") }
        let (c, t) = try expr(args[0].value, target.isNumeric ? nil : nil)
        if target == .string { return (try stringify(c, t), .string) }
        if target == .bool {
            if t == .string { return ("ws_eq(\(c), ws_lit(\"true\"))", .bool) }
            throw fail("can't convert \(t.name) to Bool")
        }
        if t == .string {
            let opt = SType.optional(target)
            guard target == .int || target == .double else { throw fail("only Int(\"12\") and Double(\"1.5\") can read text") }
            _ = try ctype(opt)
            try ensureParseHelpers()
            return (target == .double ? "ws_parse_double(\(c))" : "ws_parse_int(\(c))", opt)
        }
        guard t.isNumeric else { throw fail("can't convert \(t.name) to \(name)") }
        return ("((\(try ctype(target)))(\(c)))", target)
    }

    func numericBuiltin(_ name: String, _ given: [Arg]) throws -> (String, SType)? {
        guard ["abs", "min", "max"].contains(name) else { return nil }
        let want = name == "abs" ? 1 : 2
        guard given.count == want, given.allSatisfy({ $0.label == nil }) else { throw fail("\(name) takes \(want) unlabeled argument\(want == 1 ? "" : "s")") }
        var (c0, t0) = try expr(given[0].value, nil)
        var cs = [c0]
        if want == 2 {
            if literalish(given[0].value), !literalish(given[1].value) {
                let (c1, t1) = try expr(given[1].value, nil)
                (c0, t0) = try expr(given[0].value, t1)
                cs = [c0, c1]
            } else { cs.append(try coerce(given[1].value, to: t0)) }
        }
        guard t0 == .int || t0 == .double else { throw fail("\(name) works on Int or Double") }
        return ("ws_\(t0 == .int ? "i" : "d")\(name)(\(cs.joined(separator: ", ")))", t0)
    }

    /// print, swap and friends: things that need more than a fixed signature.
    func specialCall(_ name: String, _ args: [Arg], _ expected: SType?) throws -> (String, SType)? {
        switch name {
        case "print":
            var parts: [String] = []
            for a in args {
                if a.label != nil && a.label != "separator" && a.label != "terminator" { throw fail("print takes values to show; use string interpolation to format them") }
                if a.label != nil { continue }
                let (c, t) = try expr(a.value, nil)
                parts.append(try stringify(c, t))
            }
            let joined = parts.isEmpty ? "ws_lit(\"\")" : parts.dropFirst().reduce(parts[0]) { "ws_join(ws_join(\($0), ws_lit(\" \")), \($1))" }
            return ("wiiui_log((\(joined)).s)", .void)
        case "swap":
            guard args.count == 2, case .inoutRef(let a) = args[0].value.kind, case .inoutRef(let b) = args[1].value.kind else { throw fail("use swap(&a, &b)") }
            try requireAssignable(a); try requireAssignable(b)
            let (ac, at_) = try lvalue(a), (bc, bt) = try lvalue(b)
            guard at_ == bt else { throw fail("cannot swap \(at_.name) with \(bt.name)") }
            let t = newTmp("t")
            return ("({ \(try ctype(at_)) \(t) = \(ac); \(ac) = \(bc); \(bc) = \(t); })", .void)
        case "stride":
            throw fail("stride can only be used as the sequence of a for loop")
        case "hostCheck" where testing:
            guard args.count == 2 else { throw fail("hostCheck(ok, name)") }
            return ("host_check(\(try coerce(args[0].value, to: .bool)), (\(try coerce(args[1].value, to: .string))).s)", .void)
        case "hostValue" where testing:
            guard args.count == 2 else { throw fail("hostValue(name, value)") }
            return ("host_value((\(try coerce(args[0].value, to: .string))).s, \(try coerce(args[1].value, to: .int)))", .void)
        case "fatalError":
            if let a = args.first { _ = try coerce(a.value, to: .string) }
            return ("ws_fatal()", .void)
        case "precondition", "assert":
            guard let a = args.first else { throw fail("\(name) needs a condition") }
            return ("({ if (!(\(try coerce(a.value, to: .bool)))) ws_fatal(); })", .void)
        default: return nil
        }
    }

    func builtinCall(_ name: String, _ b: Builtin, _ given: [Arg]) throws -> (String, SType) {
        var out: [String] = []
        var k = 0
        for param in b.params {
            if k < given.count, given[k].label == param.label {
                out.append(try coerce(given[k].value, to: param.type)); k += 1
            } else if let d = param.def {
                out.append(d)
            } else {
                if k < given.count { at(given[k].value) }
                throw fail(param.label == nil ? "'\(name)' takes an unlabeled argument here" : "'\(name)' expects the label '\(param.label!):' here")
            }
        }
        if k < given.count { at(given[k].value); throw fail("extra argument in call to '\(name)'") }
        return (b.emit(out), b.ret)
    }

    func ensureParseHelpers() throws {
        if registered.contains("parsehelpers") { return }
        registered.insert("parsehelpers")
        _ = try ctype(.optional(.int)); _ = try ctype(.optional(.double))
        typeDefs.append("""
        static __attribute__((unused)) O_int ws_parse_int(wn_str s) { O_int r = {0}; char *end; long v = strtol(s.s, &end, 10); if (s.s[0] && *end == 0) { r.has = 1; r.v = (int)v; } return r; }
        static __attribute__((unused)) O_dbl ws_parse_double(wn_str s) { O_dbl r = {0}; char *end; double v = strtod(s.s, &end); if (s.s[0] && *end == 0) { r.has = 1; r.v = v; } return r; }
        """)
    }

    func numberCall(_ c: String, _ t: SType, _ name: String, _ args: [Arg]) throws -> (String, SType)? {
        switch name {
        case "squareRoot": return ("sqrt(\(c))", .double)
        case "rounded": return ("round(\(c))", t)
        case "isMultiple":
            guard args.count == 1, args[0].label == "of" else { throw fail("use isMultiple(of: n)") }
            return ("(\(c) % \(try coerce(args[0].value, to: t)) == 0)", .bool)
        case "isNaN": return ("(\(c) != \(c))", .bool)
        default: return nil
        }
    }
}
