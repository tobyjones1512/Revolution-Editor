import Foundation

nonisolated extension SwiftTranslator {
    // MARK: Scopes

    func lookupLocal(_ n: String) -> Local? { findLocal(n, in: ctx) }

    /// Looks in `c`'s scopes, then (for a lifted closure) in the function it was written in,
    /// recording what the closure captures.
    func findLocal(_ n: String, in c: FnCtx) -> Local? {
        for s in c.scopes.reversed() { if let l = s[n] { return l } }
        func view(_ l: Local) -> Local {
            c.captureByReference ? Local(type: l.type, c: "(*_cx->c_\(n))", isLet: l.isLet, captured: false)
                                 : Local(type: l.type, c: "_cx->c_\(n)", isLet: true, captured: true)
        }
        if let cap = c.captured[n] { return view(cap) }
        if let parent = c.captureParent, let l = findLocal(n, in: parent) {
            c.captured[n] = l
            return view(l)
        }
        return nil
    }

    /// Notes that generated code refers to `self` (so a closure must capture it).
    func useSelf() { ctx.usedSelf = true }

    func block(_ stmts: [Stmt], indent: Int) throws -> String {
        ctx.scopes.append([:])
        defer { ctx.scopes.removeLast() }
        return try stmts.map { try stmt($0, indent: indent) }.joined()
    }

    func indentLines(_ s: String, _ n: Int) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : ind(n) + $0 }.joined(separator: "\n")
    }

    // MARK: Declarations

    /// Declares a variable; returns its type and the C statement(s) that initialise it.
    func declare(name c: String, type: TypeExpr?, value: Expr?, global: Bool) throws -> (SType, String) {
        let annotated = try type.map(resolve)
        if let v = value {
            let (vc, vt): (String, SType)
            if let a = annotated { (vc, vt) = (try coerce(v, to: a), a) } else { (vc, vt) = try expr(v, nil) }
            if vt == .void { throw fail("'\(c)' can't be initialised from a function that returns nothing") }
            if vt == .view { throw fail("a view can only be used inside a view's body") }
            if case .tuple(let es, _) = vt, es.isEmpty { throw fail("'\(c)' can't be initialised with an empty tuple") }
            let line = global ? "\(c) = \(vc);" : "\(try decl(vt, c)) = \(vc);"
            return (vt, line)
        }
        guard let a = annotated else { throw fail("a variable needs a type or a value") }
        return (a, global ? "memset(&\(c), 0, sizeof(\(c)));" : "\(try decl(a, c)) = {0};")
    }

    func constInt(_ e: Expr) throws -> Int {
        switch e.kind {
        case .int(let n): return n
        case .ident(let n): if let v = constInts[n] { return v }
        case .binary(let op, let l, let r):
            let a = try constInt(l), b = try constInt(r)
            switch op { case "+": return a + b; case "-": return a - b; case "*": return a * b; default: break }
        default: break
        }
        at(e)
        throw fail("this must be a number or a constant (let) number")
    }

    /// Binds `pattern` to the C expression `value` of type `t`, appending declarations to `out`.
    func bind(_ pattern: Pattern, type t: SType, value: String, isLet: Bool, indent n: Int, into out: inout String) throws {
        let p = ind(n)
        switch pattern {
        case .wildcard:
            out += "\(p)(void)(\(value));\n"
        case .name(let name):
            if ctx.scopes.last?[name] != nil { throw fail("invalid redeclaration of '\(name)'") }
            let c = cname(name)
            out += "\(p)\(try decl(t, c)) = \(value);\n"
            ctx.scopes[ctx.scopes.count - 1][name] = Local(type: t, c: c, isLet: isLet)
        case .tuple(let items):
            guard case .tuple(let es, _) = t, es.count == items.count else { throw fail("this pattern has \(items.count) parts but the value is \(t.name)") }
            let tmpName = newTmp("t")
            out += "\(p)\(try decl(t, tmpName)) = \(value);\n"
            for (i, item) in items.enumerated() { try bind(item, type: es[i], value: "\(tmpName).f\(i)", isLet: isLet, indent: n, into: &out) }
        }
    }

    // MARK: Statements

    func stmt(_ s: Stmt, indent n: Int) throws -> String {
        at(s)
        let p = ind(n)
        switch s.kind {
        case .decl(let pat, let type, let value, let isLet):
            switch pat {
            case .name(let name):
                if ctx.scopes.last?[name] != nil { throw fail("invalid redeclaration of '\(name)'") }
                let c = cname(name)
                let (t, line) = try declare(name: c, type: type, value: value, global: false)
                ctx.scopes[ctx.scopes.count - 1][name] = Local(type: t, c: c, isLet: isLet)
                return indentLines(line, n) + "\n"
            default:
                guard let v = value else { throw fail("a pattern needs a value") }
                let annotated = try type.map(resolve)
                let (vc, vt) = annotated != nil ? (try coerce(v, to: annotated!), annotated!) : try expr(v, nil)
                var out = ""
                try bind(pat, type: vt, value: vc, isLet: isLet, indent: n, into: &out)
                return out
            }
        case .assign(let op, let lhs, let rhs):
            return indentLines(try assignment(op, lhs, rhs), n) + "\n"
        case .expr(let e):
            if ctx.viewMode { return try viewExpr(e, indent: n) }
            let (c, t) = try expr(e, nil)
            if t == .view { throw fail("a view can only be used inside a view's body") }
            return "\(p)\(c);\n"
        case .ifElse(let conds, let then, let els): return try ifStmt(conds, then, els, indent: n)
        case .guardElse(let conds, let els): return try guardStmt(conds, els, indent: n)
        case .whileLoop(let conds, let body):
            if conds.count == 1, case .bool(let c) = conds[0] {
                return "\(p)while (\(try condition(c))) {\n\(try block(body, indent: n + 1))\(p)}\n"
            }
            ctx.scopes.append([:])
            defer { ctx.scopes.removeLast() }
            var out = "\(p)while (1) {\n"
            out += try conditionChain(conds, indent: n + 1, failure: "break;")
            out += try block(body, indent: n + 1)
            return out + "\(p)}\n"
        case .repeatWhile(let body, let cond):
            let b = try block(body, indent: n + 1)
            return "\(p)do {\n\(b)\(p)} while (\(try condition(cond)));\n"
        case .forIn(let pat, let seq, let body): return try forStmt(pat, seq, body, indent: n)
        case .switchOn(let subject, let cases, let def): return try switchStmt(subject, cases, def, indent: n)
        case .ret(let e):
            if let frame = ctx.closures.last {
                if let e {
                    guard let rv = frame.resultVar else { throw fail("unexpected return value in a closure that returns nothing") }
                    return "\(p){ \(rv) = \(try coerce(e, to: frame.ret)); goto \(frame.label); }\n"
                }
                return "\(p)goto \(frame.label);\n"
            }
            if ctx.isInit {
                if e != nil { throw fail("an initialiser can't return a value") }
                return ctx.selfType?.isClass == true ? "\(p)return self;\n" : "\(p)return _s_;\n"
            }
            if let e {
                if ctx.ret == .void { throw fail("unexpected return value in a function that returns nothing") }
                return "\(p)return \(try coerce(e, to: ctx.ret));\n"
            }
            if ctx.ret != .void { throw fail("a return needs a value of type \(ctx.ret.name)") }
            return "\(p)return;\n"
        case .brk: return "\(p)break;\n"
        case .cont: return "\(p)continue;\n"
        case .localFunc(let f):
            return try localFunction(f)
        }
    }

    func condition(_ e: Expr) throws -> String {
        let (c, t) = try expr(e, .bool)
        guard t == .bool else { throw fail("a condition must be a Bool, not \(t.name)") }
        return stripParens(c)
    }

    func stripParens(_ c: String) -> String {
        guard c.hasPrefix("("), c.hasSuffix(")") else { return c }
        var depth = 0
        for (i, ch) in c.enumerated() {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 && i < c.count - 1 { return c } }
        }
        return String(c.dropFirst().dropLast())
    }

    // MARK: Conditions (if / guard / while)

    /// Tests each condition in turn; on failure runs `failure`. Optional bindings declare their
    /// variables in the current scope.
    func conditionChain(_ conds: [Condition], indent n: Int, failure: String) throws -> String {
        let p = ind(n)
        var out = ""
        for c in conds {
            switch c {
            case .bool(let e):
                out += "\(p)if (!(\(try condition(e)))) { \(failure) }\n"
            case .match(let pat, let valueExpr):
                let (vc, vt) = try expr(valueExpr, nil)
                guard case .named(let en) = vt, let ti = types[en], ti.kind == .enumType else { throw fail("'if case' needs an enum value, but this is \(vt.name)") }
                guard let cp = casePattern(pat), ti.cases.contains(cp.name) else { at(pat); throw fail("expected a case of \(en)") }
                let m = newTmp("m")
                let test = ti.hasPayload ? "\(m).tag != T_\(en)_\(cp.name)" : "\(m) != T_\(en)_\(cp.name)"
                out += "\(p)T_\(en) \(m) = \(vc);\n\(p)if (\(test)) { \(failure) }\n"
                try bindCasePattern(ti, cp.name, cp.args, value: m, indent: n, into: &out)
            case .bind(let pat, let e, let isVar):
                let (ec, et) = try expr(e, nil)
                guard case .optional(let inner) = et else { throw fail("an optional binding needs an optional value, but this is \(et.name)") }
                let o = newTmp("o")
                out += "\(p)\(try ctype(et)) \(o) = \(ec);\n\(p)if (!\(o).has) { \(failure) }\n"
                try bind(pat, type: inner, value: "\(o).v", isLet: !isVar, indent: n, into: &out)
            }
        }
        return out
    }

    func ifStmt(_ conds: [Condition], _ then: [Stmt], _ els: [Stmt]?, indent n: Int) throws -> String {
        let p = ind(n)
        if conds.count == 1, case .bool(let c) = conds[0] {
            var out = "\(p)if (\(try condition(c))) {\n\(try block(then, indent: n + 1))\(p)}"
            if let els {
                if els.count == 1, case .ifElse(let c2, let t2, let e2) = els[0].kind, c2.count == 1, case .bool = c2[0] {
                    at(els[0])
                    out += " else " + String((try ifStmt(c2, t2, e2, indent: n)).dropFirst(p.count))
                    return out
                }
                out += " else {\n\(try block(els, indent: n + 1))\(p)}"
            }
            return out + "\n"
        }
        let id = newTmp("if")
        ctx.scopes.append([:])
        var out = "\(p){\n"
        out += try conditionChain(conds, indent: n + 1, failure: "goto \(id)_else;")
        out += "\(p)    {\n" + (try block(then, indent: n + 2)) + "\(p)    }\n"
        ctx.scopes.removeLast()
        out += "\(p)    goto \(id)_end;\n\(p)    \(id)_else: ;\n"
        if let els { out += "\(p)    {\n" + (try block(els, indent: n + 2)) + "\(p)    }\n" }
        return out + "\(p)    \(id)_end: ;\n\(p)}\n"
    }

    func guardStmt(_ conds: [Condition], _ els: [Stmt], indent n: Int) throws -> String {
        // The else body runs when a condition fails; bindings stay in scope afterwards.
        var out = ""
        for c in conds {
            let elseBody = try block(els, indent: n + 1)
            let failure = "\n" + elseBody + ind(n)
            out += try conditionChain([c], indent: n, failure: failure)
        }
        return out
    }

    // MARK: Assignment

    func assignment(_ op: String, _ lhs: Expr, _ rhs: Expr) throws -> String {
        if case .ident("_") = lhs.kind { return "(void)(\(try expr(rhs, nil).0));" }
        if case .tupleLit(let items) = lhs.kind {
            let (rc, rt) = try expr(rhs, nil)
            guard case .tuple(let es, _) = rt, es.count == items.count else { throw fail("this assigns \(items.count) values but the right side is \(rt.name)") }
            let t = newTmp("t")
            var out = "{ \(try decl(rt, t)) = \(rc);"
            for (i, item) in items.enumerated() {
                try requireAssignable(item.value)
                let (lc, lt) = try lvalue(item.value)
                guard lt == es[i] else { throw fail("cannot assign \(es[i].name) to \(lt.name)") }
                out += " \(lc) = \(t).f\(i);"
            }
            return out + " }"
        }
        // dict[key] = value / dict[key, default: 0] += 1
        if let r = try dictAssignment(op, lhs, rhs) { return r }
        // Computed property setter
        if let setter = try computedSetter(lhs) {
            if op == "=" { return "\(setter.callee)(\(setter.args)\(try coerce(rhs, to: setter.type)));" }
            let (cur, _) = try expr(lhs, nil)
            let bop = String(op.dropLast())
            return "\(setter.callee)(\(setter.args)\(try binaryCode(bop, cur, setter.type, try coerce(rhs, to: setter.type), setter.type)));"
        }
        try requireAssignable(lhs)
        let (lc, lt) = try lvalue(lhs)
        if op == "=" { return "\(lc) = \(try coerce(rhs, to: lt));" }
        let bop = String(op.dropLast())
        if case .array = lt {
            if bop == "+" { return "\(lc) = \(try arrayConcat(lc, lt, try coerce(rhs, to: lt)));" }
            throw fail("operator '\(op)' can't be applied to \(lt.name)")
        }
        if lt == .string {
            guard bop == "+" else { throw fail("operator '\(op)' can't be applied to String") }
            return "\(lc) = ws_join(\(lc), \(try coerce(rhs, to: .string)));"
        }
        guard lt.isNumeric else { throw fail("operator '\(op)' can't be applied to \(lt.name)") }
        if lt.isFloating, ["%", "&", "|", "^"].contains(bop) { throw fail("operator '\(op)' needs integers") }
        return "\(lc) \(op) \(try coerce(rhs, to: lt));"
    }

    func dictAssignment(_ op: String, _ lhs: Expr, _ rhs: Expr) throws -> String? {
        var baseExpr: Expr, key: Expr, def: Expr?
        switch lhs.kind {
        case .subscripted(let b, let k): baseExpr = b; key = k; def = nil
        case .dictSubscriptDefault(let b, let k, let d): baseExpr = b; key = k; def = d
        default: return nil
        }
        guard let (_, bt) = try? expr(baseExpr, nil), case .dict(let kt, let vt) = bt else { return nil }
        try requireAssignable(baseExpr)
        let l = try lvalue(baseExpr).0
        let m = bt.mangled
        let k = newTmp("k")
        let keyC = try coerce(key, to: kt)
        if op == "=" {
            if case .nilLit = rhs.kind { return "{ \(try decl(kt, k)) = \(keyC); \(m)_remove(&\(l), \(k)); }" }
            // Assigning an optional value: set when present.
            if let (rc0, rt0) = try? expr(rhs, nil), case .optional(let inner) = rt0, inner == vt {
                let o = newTmp("o")
                return "{ \(try decl(kt, k)) = \(keyC); \(try ctype(rt0)) \(o) = \(rc0); if (\(o).has) \(m)_set(&\(l), \(k), \(o).v); else \(m)_remove(&\(l), \(k)); }"
            }
            return "{ \(try decl(kt, k)) = \(keyC); \(m)_set(&\(l), \(k), \(try coerce(rhs, to: vt))); }"
        }
        // Compound assignment needs a starting value.
        guard let def else { throw fail("use dict[key, default: 0] \(op) ... for compound assignment on a dictionary") }
        let bop = String(op.dropLast())
        let i = newTmp("i"), cur = newTmp("v")
        let current = "\(l).v[\(i)]"
        let combined: String
        if vt == .string { guard bop == "+" else { throw fail("operator '\(op)' can't be applied to String") }; combined = "ws_join(\(cur), \(try coerce(rhs, to: .string)))" }
        else { guard vt.isNumeric else { throw fail("operator '\(op)' can't be applied to \(vt.name)") }; combined = try binaryCode(bop, cur, vt, try coerce(rhs, to: vt), vt) }
        _ = current
        return "{ \(try decl(kt, k)) = \(keyC); int \(i) = \(m)_find(&\(l), \(k)); \(try decl(vt, cur)) = \(i) >= 0 ? \(l).v[\(i)] : (\(try coerce(def, to: vt))); \(m)_set(&\(l), \(k), \(combined)); }"
    }

    /// `x.area = 5` where `area` has a setter: the call to make instead of an assignment.
    func computedSetter(_ lhs: Expr) throws -> (callee: String, args: String, type: SType)? {
        var baseExpr: Expr?, name = ""
        switch lhs.kind {
        case .member(let b, let n, optional: false): baseExpr = b; name = n
        case .ident(let n):
            guard let ti = ctx.selfType, lookupLocal(n) == nil, let p = ti.props.first(where: { $0.name == n && $0.isComputed }) else { return nil }
            guard p.decl.setter != nil else { throw fail("'\(n)' is a get-only property") }
            let prefix = ti.isClass ? "C_" : "T_"
            return p.decl.isStatic ? ("\(prefix)\(ti.name)_set_\(n)", "", p.type) : ("\(prefix)\(ti.name)_set_\(n)", "self, ", p.type)
        default: return nil
        }
        guard let b = baseExpr else { return nil }
        // Static: Type.prop = v
        if case .ident(let tn) = b.kind, lookupLocal(tn) == nil, globals[tn] == nil, let ti = types[tn], let p = ti.props.first(where: { $0.name == name && $0.isComputed && $0.decl.isStatic }) {
            guard p.decl.setter != nil else { throw fail("'\(name)' is a get-only property") }
            return ("\(ti.isClass ? "C_" : "T_")\(tn)_set_\(name)", "", p.type)
        }
        if staticTypeName(b) != nil { return nil }
        let bt: SType
        if case .selfRef = b.kind, let st = ctx.selfType { bt = .named(st.name) } else { bt = try expr(b, nil).1 }
        guard let ti = info(bt), let p = ti.props.first(where: { $0.name == name && $0.isComputed }) else { return nil }
        guard p.decl.setter != nil else { throw fail("'\(name)' is a get-only property") }
        try requireAssignable(b)
        let (bc, _) = try lvalue(b)
        let prefix = ti.isClass ? "C_" : "T_"
        return ("\(prefix)\(ti.name)_set_\(name)", ti.isClass ? "\(bc), " : "&\(bc), ", p.type)
    }

    func requireAssignable(_ e: Expr) throws {
        switch e.kind {
        case .ident(let n):
            if let l = lookupLocal(n) {
                if l.captured { at(e); throw fail("a closure can't change the local variable '\(n)': it only has a copy. Use a property or a global instead") }
                if l.isLet { at(e); throw fail("cannot assign to '\(n)': it is a 'let' constant") }
                return
            }
            if let ti = ctx.selfType, let p = ti.props.first(where: { $0.name == n }) {
                if p.decl.isStatic { if p.decl.isLet { at(e); throw fail("cannot assign to '\(n)': it is a 'let' constant") }; return }
                if p.decl.isLet && !ctx.isInit { at(e); throw fail("cannot assign to '\(n)': it is a 'let' constant") }
                if !ctx.isMutating { at(e); throw fail("cannot assign to property '\(n)': mark the method 'mutating'") }
                return
            }
            if let g = globals[n] { if g.isLet { at(e); throw fail("cannot assign to '\(n)': it is a 'let' constant") }; return }
            at(e); throw fail("cannot find '\(n)' in scope")
        case .selfRef:
            if !ctx.isMutating { at(e); throw fail("cannot assign to self: mark the method 'mutating'") }
        case .member(let b, let name, optional: false):
            if case .selfRef = b.kind {
                if let p = ctx.selfType?.props.first(where: { $0.name == name }), p.decl.isLet, !ctx.isInit { at(e); throw fail("cannot assign to '\(name)': it is a 'let' constant") }
                if !ctx.isMutating { at(e); throw fail("cannot assign to a property of self: mark the method 'mutating'") }
                return
            }
            if case .ident(let tn) = b.kind, lookupLocal(tn) == nil, globals[tn] == nil, types[tn] != nil { return }   // static
            // A class instance can always be changed through a `let`.
            let bt = try expr(b, nil).1
            if isClass(bt) { return }
            try requireAssignable(b)
        case .subscripted(let b, _): try requireAssignable(b)
        case .dictSubscriptDefault(let b, _, _): try requireAssignable(b)
        case .tupleIndex(let b, _): try requireAssignable(b)
        case .forceUnwrap(let b): try requireAssignable(b)
        default: at(e); throw fail("this can't be assigned to")
        }
    }

    /// A C lvalue for an assignable expression.
    func lvalue(_ e: Expr) throws -> (String, SType) {
        at(e)
        switch e.kind {
        case .ident, .selfRef: return try expr(e, nil)
        case .member(let b, let name, optional: false):
            if case .ident(let tn) = b.kind, lookupLocal(tn) == nil, globals[tn] == nil, let ti = types[tn],
               let p = ti.props.first(where: { $0.name == name && $0.decl.isStatic }) {
                return ("\(ti.isClass ? "C_" : "T_")\(tn)_\(name)", p.type)
            }
            let (bc, bt) = try lvalueOrValue(b)
            guard let ti = info(bt), let p = ti.props.first(where: { $0.name == name && !$0.isComputed && !$0.decl.isStatic }) else {
                if case .tuple(let es, let labels) = bt, let i = labels.firstIndex(where: { $0 == name }) { return ("\(bc).f\(i)", es[i]) }
                throw fail("'\(bt.name)' has no assignable property '\(name)'")
            }
            let access = ti.isClass ? "\(bc)->\(cname(name))" : "\(bc).\(cname(name))"
            return (p.isBinding ? "(*\(access))" : access, p.type)
        case .subscripted(let b, let idx):
            let (bc, bt) = try lvalue(b)
            guard case .array(let elem) = bt else { throw fail("cannot subscript a value of type '\(bt.name)'") }
            return ("\(bc).a[ws_idx(\(try coerce(idx, to: .int)), \(bc).n)]", elem)
        case .tupleIndex(let b, let i):
            let (bc, bt) = try lvalue(b)
            guard case .tuple(let es, _) = bt, i < es.count else { throw fail("tuple has no element \(i)") }
            return ("\(bc).f\(i)", es[i])
        case .forceUnwrap(let b):
            let (bc, bt) = try lvalue(b)
            guard case .optional(let inner) = bt else { throw fail("cannot force unwrap a value that isn't optional") }
            return ("\(bc).v", inner)
        default: throw fail("this can't be assigned to")
        }
    }

    /// For member bases: an lvalue where possible, else just the value (class references).
    func lvalueOrValue(_ b: Expr) throws -> (String, SType) {
        if let r = try? lvalue(b) { return r }
        return try expr(b, nil)
    }

    // MARK: Loops

    func forStmt(_ pat: Pattern, _ seq: Expr, _ body: [Stmt], indent n: Int) throws -> String {
        let p = ind(n)
        ctx.scopes.append([:])
        defer { ctx.scopes.removeLast() }

        // Ranges, including (a..<b).reversed()
        var rangeExpr: Expr?, reversed = false
        if case .range = seq.kind { rangeExpr = seq }
        if case .call(let callee, let args) = seq.kind, args.isEmpty, case .member(let base, "reversed", optional: false) = callee.kind, case .range = base.kind { rangeExpr = base; reversed = true }
        if let r = rangeExpr, case .range(let lo, let hi, let inclusive) = r.kind {
            let lc = try coerce(lo, to: .int), hc = try coerce(hi, to: .int)
            let end = newTmp("end")
            var pre = ""
            let v: String
            switch pat {
            case .name(let name): v = cname(name); ctx.scopes[ctx.scopes.count - 1][name] = Local(type: .int, c: v, isLet: true)
            case .wildcard: v = newTmp("i")
            case .tuple: throw fail("a range gives numbers, not tuples")
            }
            _ = pre; pre = ""
            let limit = inclusive ? "\(hc) + 1" : hc
            let loop = reversed
                ? "for (int \(v) = \(end) - 1; \(v) >= \(lc); \(v)--)"
                : "for (int \(v) = \(lc); \(v) < \(end); \(v)++)"
            return "\(p){\n\(p)    int \(end) = \(limit);\n\(p)    \(loop) {\n\(try block(body, indent: n + 2))\(p)    }\n\(p)}\n"
        }
        // stride(from:to:by:)
        if case .call(let callee, let args) = seq.kind, case .ident("stride") = callee.kind, args.count == 3,
           args[0].label == "from", args[2].label == "by", let l1 = args[1].label, l1 == "to" || l1 == "through" {
            let start = try coerce(args[0].value, to: .int), end = try coerce(args[1].value, to: .int), step = try coerce(args[2].value, to: .int)
            let v: String
            switch pat {
            case .name(let name): v = cname(name); ctx.scopes[ctx.scopes.count - 1][name] = Local(type: .int, c: v, isLet: true)
            default: v = newTmp("i")
            }
            let e = newTmp("e"), s = newTmp("s")
            let cmp = l1 == "to" ? "(\(s) > 0 ? \(v) < \(e) : \(v) > \(e))" : "(\(s) > 0 ? \(v) <= \(e) : \(v) >= \(e))"
            return "\(p){\n\(p)    int \(e) = \(end), \(s) = \(step);\n\(p)    if (\(s) == 0) ws_fatal();\n\(p)    for (int \(v) = \(start); \(cmp); \(v) += \(s)) {\n\(try block(body, indent: n + 2))\(p)    }\n\(p)}\n"
        }
        // enumerated() / reversed() / indices
        var enumerate = false, reverseArray = false
        var arrayExpr = seq
        if case .call(let callee, let args) = seq.kind, args.isEmpty, case .member(let base, let m, optional: false) = callee.kind {
            if m == "enumerated" { enumerate = true; arrayExpr = base }
            else if m == "reversed" { reverseArray = true; arrayExpr = base }
        }
        if case .member(let base, "indices", optional: false) = seq.kind {
            let (bc, bt) = try expr(base, nil)
            guard case .array = bt else { throw fail("'indices' needs an array") }
            let v: String
            switch pat {
            case .name(let name): v = cname(name); ctx.scopes[ctx.scopes.count - 1][name] = Local(type: .int, c: v, isLet: true)
            default: v = newTmp("i")
            }
            let a = newTmp("a")
            return "\(p){\n\(p)    \(try ctype(bt)) \(a) = \(bc);\n\(p)    for (int \(v) = 0; \(v) < \(a).n; \(v)++) {\n\(try block(body, indent: n + 2))\(p)    }\n\(p)}\n"
        }
        let (ac, at_) = try expr(arrayExpr, nil)
        if case .dict(let kt, let vt) = at_ {
            guard case .tuple(let items) = pat, items.count == 2 else { throw fail("loop over a dictionary with `for (key, value) in dict`") }
            let d = newTmp("d"), k = newTmp("k")
            var binds = ""
            try bind(items[0], type: kt, value: "\(d).k[\(k)]", isLet: true, indent: n + 2, into: &binds)
            try bind(items[1], type: vt, value: "\(d).v[\(k)]", isLet: true, indent: n + 2, into: &binds)
            return "\(p){\n\(p)    \(try ctype(at_)) \(d) = \(ac);\n\(p)    for (int \(k) = 0; \(k) < \(d).n; \(k)++) {\n\(binds)\(try block(body, indent: n + 2))\(p)    }\n\(p)}\n"
        }
        guard case .array(let elem) = at_ else { throw fail("can only loop over a range, an array or a dictionary, not \(at_.name)") }
        let a = newTmp("a"), k = newTmp("k")
        var out = "\(p){\n\(p)    \(try ctype(at_)) \(a) = \(ac);\n"
        let header = reverseArray ? "for (int \(k) = \(a).n - 1; \(k) >= 0; \(k)--)" : "for (int \(k) = 0; \(k) < \(a).n; \(k)++)"
        out += "\(p)    \(header) {\n"
        var binds = ""
        if enumerate {
            guard case .tuple(let items) = pat, items.count == 2 else { throw fail("enumerated() needs a pattern like (index, value)") }
            try bind(items[0], type: .int, value: k, isLet: true, indent: n + 2, into: &binds)
            try bind(items[1], type: elem, value: "\(a).a[\(k)]", isLet: true, indent: n + 2, into: &binds)
        } else {
            try bind(pat, type: elem, value: "\(a).a[\(k)]", isLet: true, indent: n + 2, into: &binds)
        }
        out += binds
        out += try block(body, indent: n + 2)
        return out + "\(p)    }\n\(p)}\n"
    }

    // MARK: Switch

    func switchStmt(_ subject: Expr, _ cases: [(patterns: [Expr], body: [Stmt])], _ def: [Stmt]?, indent n: Int) throws -> String {
        let p = ind(n)
        let (sc, st) = try expr(subject, nil)
        if case .named(let en) = st, let e = types[en], e.kind == .enumType {
            var covered = Set<String>()
            for c in cases { for pat in c.patterns { if let cp = casePattern(pat) { covered.insert(cp.name) } } }
            if def == nil, !Set(e.cases).isSubset(of: covered) { throw fail("switch must be exhaustive: add the missing cases or a default") }
            if e.hasPayload { return try payloadSwitch(sc, e, cases, def, indent: n) }
        } else if def == nil { throw fail("switch must be exhaustive: add a default case") }

        if st == .string {
            var out = "", first = true
            let s = newTmp("s")
            out += "\(p){\n\(p)    wn_str \(s) = \(sc);\n"
            for c in cases {
                let conds = try c.patterns.map { "ws_eq(\(s), \(try coerce($0, to: .string)))" }.joined(separator: " || ")
                out += "\(p)    \(first ? "" : "else ")if (\(conds)) {\n\(try block(c.body, indent: n + 2))\(p)    }\n"
                first = false
            }
            if let def { out += "\(p)    else {\n\(try block(def, indent: n + 2))\(p)    }\n" }
            return out + "\(p)}\n"
        }
        guard st.isInteger || st == .bool || isEnum(st) else { throw fail("can't switch on a value of type \(st.name)") }
        var out = "\(p)switch (\(sc)) {\n"
        for c in cases {
            for pat in c.patterns {
                if case .range(let lo, let hi, let inclusive) = pat.kind {
                    let h = try coerce(hi, to: st)
                    out += "\(p)case \(try coerce(lo, to: st)) ... \(inclusive ? h : "(\(h)) - 1"):\n"
                } else { out += "\(p)case \(try coerce(pat, to: st)):\n" }
            }
            out += "\(p){\n\(try block(c.body, indent: n + 1))\(p)    break;\n\(p)}\n"
        }
        if let def { out += "\(p)default:\n\(p){\n\(try block(def, indent: n + 1))\(p)    break;\n\(p)}\n" }
        return out + "\(p)}\n"
    }

    // MARK: Nested functions

    /// A nested function becomes a top-level one. It can't use the enclosing function's variables.
    func localFunction(_ f: FuncDecl) throws -> String {
        let outerCtx = ctx
        let outerFile = curFile
        var info = try funcInfo(f, owner: nil)
        info.cName = "sw_local\(tmp + 1)_\(f.name)"
        tmp += 1
        try emitPrototype(info)
        outerCtx.localFuncs[f.name] = info
        let code = try function(info)
        bodies.append(code)
        ctx = outerCtx
        curFile = outerFile
        return ""
    }
}
