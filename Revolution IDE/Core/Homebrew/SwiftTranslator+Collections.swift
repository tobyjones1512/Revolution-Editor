import Foundation

nonisolated extension SwiftTranslator {
    // MARK: Arrays

    func arrayConstruct(_ arrayType: SType, _ args: [Arg]) throws -> (String, SType) {
        guard case .array(let elem) = arrayType else { throw fail("expected an array type") }
        let ac = try ctype(arrayType)
        if args.isEmpty { return ("((\(ac)){0})", arrayType) }
        guard args.count == 2, args[0].label == "repeating", args[1].label == "count" else { throw fail("use [T](), or [T](repeating: value, count: n)") }
        let v = try coerce(args[0].value, to: elem), n = try coerce(args[1].value, to: .int)
        let r = newTmp("r"), cnt = newTmp("n"), i = newTmp("i"), val = newTmp("v")
        return ("({ \(ac) \(r) = {0}; int \(cnt) = \(n); if (\(cnt) < 0 || \(cnt) > \(capacity(elem))) ws_fatal(); \(try decl(elem, val)) = \(v); for (int \(i) = 0; \(i) < \(cnt); \(i)++) \(r).a[\(i)] = \(val); \(r).n = \(cnt); \(r); })", arrayType)
    }

    func arrayConcat(_ a: String, _ t: SType, _ b: String) throws -> String {
        guard case .array(let elem) = t else { throw fail("expected arrays") }
        let ac = try ctype(t)
        let x = newTmp("x"), y = newTmp("y"), i = newTmp("i")
        _ = elem
        return "({ \(ac) \(x) = \(a), \(y) = \(b); for (int \(i) = 0; \(i) < \(y).n; \(i)++) \(ctype2(t))_append(&\(x), \(y).a[\(i)]); \(x); })"
    }

    func ctype2(_ t: SType) -> String { t.mangled }

    func arrayProperty(_ bc: String, _ bt: SType, _ name: String) throws -> (String, SType)? {
        guard case .array(let elem) = bt else { return nil }
        let a = newTmp("a")
        switch name {
        case "count": return ("((int)(\(bc)).n)", .int)
        case "isEmpty": return ("((\(bc)).n == 0)", .bool)
        case "first", "last":
            let opt = SType.optional(elem)
            let idx = name == "first" ? "0" : "\(a).n - 1"
            return ("({ \(try ctype(bt)) \(a) = \(bc); \(try ctype(opt)) _r = {0}; if (\(a).n) { _r.has = 1; _r.v = \(a).a[\(idx)]; } _r; })", opt)
        default: return nil
        }
    }

    /// Whether `<` is meaningful for `t`, and its C text.
    func lessThan(_ a: String, _ b: String, _ t: SType) throws -> String {
        if t == .string { return "(strcmp((\(a)).s, (\(b)).s) < 0)" }
        guard t.isNumeric else { throw fail("elements of type \(t.name) can't be ordered; give a comparison closure") }
        return "((\(a)) < (\(b)))"
    }

    func arrayCall(_ obj: Expr, _ oc: String, _ ot: SType, _ name: String, _ args: [Arg]) throws -> (String, SType)? {
        guard case .array(let elem) = ot else { return nil }
        let m = ot.mangled
        let ac = try ctype(ot)
        func lv() throws -> String {
            try requireAssignable(obj)
            return try lvalue(obj).0
        }
        func labels(_ ls: [String?]) throws {
            guard args.count == ls.count, zip(args, ls).allSatisfy({ $0.label == $1 }) else { throw fail("'\(name)' doesn't take these arguments") }
        }
        let a = newTmp("a"), i = newTmp("i")

        switch name {
        // Mutating
        case "append":
            if args.count == 1, args[0].label == "contentsOf" {
                let l = try lv(), other = try coerce(args[0].value, to: ot), o = newTmp("o")
                return ("({ \(ac) \(o) = \(other); for (int \(i) = 0; \(i) < \(o).n; \(i)++) \(m)_append(&\(l), \(o).a[\(i)]); })", .void)
            }
            try labels([nil])
            return ("\(m)_append(&\(try lv()), \(try coerce(args[0].value, to: elem)))", .void)
        case "insert":
            try labels([nil, "at"])
            return ("\(m)_insert(&\(try lv()), \(try coerce(args[1].value, to: .int)), \(try coerce(args[0].value, to: elem)))", .void)
        case "remove":
            try labels(["at"])
            return ("\(m)_removeAt(&\(try lv()), \(try coerce(args[0].value, to: .int)))", elem)
        case "removeFirst":
            try labels([])
            return ("\(m)_removeAt(&\(try lv()), 0)", elem)
        case "removeLast":
            try labels([])
            let l = try lv()
            return ("\(m)_removeAt(&\(l), \(l).n - 1)", elem)
        case "popLast":
            try labels([])
            let l = try lv(), opt = SType.optional(elem)
            return ("({ \(try ctype(opt)) _r = {0}; if (\(l).n) { _r.has = 1; _r.v = \(m)_removeAt(&\(l), \(l).n - 1); } _r; })", opt)
        case "removeAll":
            try labels([])
            return ("(\(try lv()).n = 0)", .void)
        case "swapAt":
            try labels([nil, nil])
            let l = try lv(), x = newTmp("x"), y = newTmp("y"), t = newTmp("t")
            return ("({ int \(x) = \(try coerce(args[0].value, to: .int)), \(y) = \(try coerce(args[1].value, to: .int)); if (\(x) < 0 || \(x) >= \(l).n || \(y) < 0 || \(y) >= \(l).n) ws_fatal(); \(try decl(elem, t)) = \(l).a[\(x)]; \(l).a[\(x)] = \(l).a[\(y)]; \(l).a[\(y)] = \(t); })", .void)
        case "reverse":
            try labels([])
            let l = try lv(), t = newTmp("t")
            return ("({ for (int \(i) = 0; \(i) < \(l).n / 2; \(i)++) { \(try decl(elem, t)) = \(l).a[\(i)]; \(l).a[\(i)] = \(l).a[\(l).n - 1 - \(i)]; \(l).a[\(l).n - 1 - \(i)] = \(t); } })", .void)
        case "sort":
            let l = try lv()
            let code = try sortCode(l, ot, elem, args)
            return ("(\(l) = \(code))", .void)

        // Non-mutating
        case "sorted":
            return (try sortCode(oc, ot, elem, args), ot)
        case "reversed":
            try labels([])
            let r = newTmp("r")
            return ("({ \(ac) \(a) = \(oc), \(r) = {0}; for (int \(i) = \(a).n - 1; \(i) >= 0; \(i)--) \(r).a[\(r).n++] = \(a).a[\(i)]; \(r); })", ot)
        case "contains":
            if args.count == 1, args[0].label == nil {
                let x = newTmp("x")
                let eq = try equalityCode("\(a).a[\(i)]", x, elem)
                return ("({ \(ac) \(a) = \(oc); \(try decl(elem, x)) = \(try coerce(args[0].value, to: elem)); int _f = 0; for (int \(i) = 0; \(i) < \(a).n && !_f; \(i)++) if (\(eq)) _f = 1; _f; })", .bool)
            }
            guard args.count == 1, args[0].label == "where" else { throw fail("use contains(x) or contains(where: { ... })") }
            let (test, _) = try applyClosure(args[0].value, [elem], .bool, ["\(a).a[\(i)]"])
            return ("({ \(ac) \(a) = \(oc); int _f = 0; for (int \(i) = 0; \(i) < \(a).n && !_f; \(i)++) if (\(test)) _f = 1; _f; })", .bool)
        case "allSatisfy":
            try labels([nil])
            let (test, _) = try applyClosure(args[0].value, [elem], .bool, ["\(a).a[\(i)]"])
            return ("({ \(ac) \(a) = \(oc); int _f = 1; for (int \(i) = 0; \(i) < \(a).n && _f; \(i)++) if (!(\(test))) _f = 0; _f; })", .bool)
        case "first" where args.count == 1 && args[0].label == "where":
            let (test, _) = try applyClosure(args[0].value, [elem], .bool, ["\(a).a[\(i)]"])
            let opt = SType.optional(elem)
            return ("({ \(ac) \(a) = \(oc); \(try ctype(opt)) _r = {0}; for (int \(i) = 0; \(i) < \(a).n && !_r.has; \(i)++) if (\(test)) { _r.has = 1; _r.v = \(a).a[\(i)]; } _r; })", opt)
        case "firstIndex":
            let opt = SType.optional(.int)
            _ = try ctype(opt)
            if args.count == 1, args[0].label == "of" {
                let x = newTmp("x")
                let eq = try equalityCode("\(a).a[\(i)]", x, elem)
                return ("({ \(ac) \(a) = \(oc); \(try decl(elem, x)) = \(try coerce(args[0].value, to: elem)); O_int _r = {0}; for (int \(i) = 0; \(i) < \(a).n && !_r.has; \(i)++) if (\(eq)) { _r.has = 1; _r.v = \(i); } _r; })", opt)
            }
            guard args.count == 1, args[0].label == "where" else { throw fail("use firstIndex(of: x) or firstIndex(where: { ... })") }
            let (test, _) = try applyClosure(args[0].value, [elem], .bool, ["\(a).a[\(i)]"])
            return ("({ \(ac) \(a) = \(oc); O_int _r = {0}; for (int \(i) = 0; \(i) < \(a).n && !_r.has; \(i)++) if (\(test)) { _r.has = 1; _r.v = \(i); } _r; })", opt)
        case "filter":
            try labels([nil])
            let (test, _) = try applyClosure(args[0].value, [elem], .bool, ["\(a).a[\(i)]"])
            let r = newTmp("r")
            return ("({ \(ac) \(a) = \(oc), \(r) = {0}; for (int \(i) = 0; \(i) < \(a).n; \(i)++) if (\(test)) \(m)_append(&\(r), \(a).a[\(i)]); \(r); })", ot)
        case "map", "compactMap":
            try labels([nil])
            let (val, vt) = try applyClosure(args[0].value, [elem], nil, ["\(a).a[\(i)]"])
            let r = newTmp("r")
            if name == "compactMap" {
                guard case .optional(let inner) = vt else { throw fail("compactMap's closure must return an optional") }
                let outT = SType.array(inner)
                let o = newTmp("o")
                return ("({ \(ac) \(a) = \(oc); \(try ctype(outT)) \(r) = {0}; for (int \(i) = 0; \(i) < \(a).n; \(i)++) { \(try ctype(vt)) \(o) = \(val); if (\(o).has) \(outT.mangled)_append(&\(r), \(o).v); } \(r); })", outT)
            }
            let outT = SType.array(vt)
            return ("({ \(ac) \(a) = \(oc); \(try ctype(outT)) \(r) = {0}; for (int \(i) = 0; \(i) < \(a).n; \(i)++) \(outT.mangled)_append(&\(r), \(val)); \(r); })", outT)
        case "forEach":
            try labels([nil])
            let (body, _) = try applyClosure(args[0].value, [elem], .void, ["\(a).a[\(i)]"])
            return ("({ \(ac) \(a) = \(oc); for (int \(i) = 0; \(i) < \(a).n; \(i)++) { \(body); } })", .void)
        case "reduce":
            guard args.count == 2, args[0].label == nil, args[1].label == nil else { throw fail("use reduce(initial) { acc, x in ... } or reduce(initial, +)") }
            let (ic, it) = try expr(args[0].value, nil)
            let acc = newTmp("acc")
            let (step, st) = try applyClosure(args[1].value, [it, elem], it, [acc, "\(a).a[\(i)]"])
            guard st == it else { throw fail("reduce's closure must return \(it.name)") }
            return ("({ \(ac) \(a) = \(oc); \(try decl(it, acc)) = \(ic); for (int \(i) = 0; \(i) < \(a).n; \(i)++) \(acc) = \(step); \(acc); })", it)
        case "min", "max":
            let opt = SType.optional(elem)
            let cmp = try lessThan(name == "min" ? "\(a).a[\(i)]" : "_r.v", name == "min" ? "_r.v" : "\(a).a[\(i)]", elem)
            return ("({ \(ac) \(a) = \(oc); \(try ctype(opt)) _r = {0}; for (int \(i) = 0; \(i) < \(a).n; \(i)++) { if (!_r.has || \(cmp)) { _r.has = 1; _r.v = \(a).a[\(i)]; } } _r; })", opt)
        case "joined":
            guard elem == .string else { throw fail("joined() needs an array of String") }
            var sep = "ws_lit(\"\")"
            if let s = args.first { guard s.label == "separator" else { throw fail("use joined(separator: \", \")") }; sep = try coerce(s.value, to: .string) }
            return ("({ \(ac) \(a) = \(oc); wn_str _r = ws_lit(\"\"), _s = \(sep); for (int \(i) = 0; \(i) < \(a).n; \(i)++) { if (\(i)) _r = ws_join(_r, _s); _r = ws_join(_r, \(a).a[\(i)]); } _r; })", .string)
        case "prefix", "dropFirst", "dropLast", "suffix":
            let n = args.isEmpty ? "1" : try coerce(args[0].value, to: .int)
            let r = newTmp("r"), k = newTmp("k")
            let range: String
            switch name {
            case "prefix": range = "0, (\(k) < \(a).n ? \(k) : \(a).n)"
            case "suffix": range = "(\(k) < \(a).n ? \(a).n - \(k) : 0), \(a).n"
            case "dropFirst": range = "(\(k) < \(a).n ? \(k) : \(a).n), \(a).n"
            default: range = "0, (\(k) < \(a).n ? \(a).n - \(k) : 0)"
            }
            return ("({ \(ac) \(a) = \(oc), \(r) = {0}; int \(k) = \(n); int _lo = 0, _hi = 0; { int p[2] = { \(range) }; _lo = p[0]; _hi = p[1]; } for (int \(i) = _lo; \(i) < _hi; \(i)++) \(m)_append(&\(r), \(a).a[\(i)]); \(r); })", ot)
        default: return nil
        }
    }

    /// An insertion sort over a copy of `arr`: by `<` or by a comparison closure.
    func sortCode(_ arr: String, _ at_: SType, _ elem: SType, _ args: [Arg]) throws -> String {
        let r = newTmp("r"), i = newTmp("i"), j = newTmp("j"), key = newTmp("k")
        var less: String
        if args.isEmpty { less = try lessThan(key, "\(r).a[\(j)]", elem) }
        else {
            guard args.count == 1, args[0].label == "by" else { throw fail("use sorted() or sorted(by: { a, b in ... })") }
            less = try applyClosure(args[0].value, [elem, elem], .bool, [key, "\(r).a[\(j)]"]).0
        }
        return "({ \(try ctype(at_)) \(r) = \(arr); for (int \(i) = 1; \(i) < \(r).n; \(i)++) { \(try decl(elem, key)) = \(r).a[\(i)]; int \(j) = \(i) - 1; while (\(j) >= 0 && \(less)) { \(r).a[\(j) + 1] = \(r).a[\(j)]; \(j)--; } \(r).a[\(j) + 1] = \(key); } \(r); })"
    }

    // MARK: Dictionaries

    func dictProperty(_ bc: String, _ bt: SType, _ name: String) throws -> (String, SType)? {
        guard case .dict(let kt, let vt) = bt else { return nil }
        let d = newTmp("d"), i = newTmp("i")
        switch name {
        case "count": return ("((int)(\(bc)).n)", .int)
        case "isEmpty": return ("((\(bc)).n == 0)", .bool)
        case "keys", "values":
            let et = name == "keys" ? kt : vt, at_ = SType.array(et)
            let r = newTmp("r")
            return ("({ \(try ctype(bt)) \(d) = \(bc); \(try ctype(at_)) \(r) = {0}; for (int \(i) = 0; \(i) < \(d).n; \(i)++) \(at_.mangled)_append(&\(r), \(d).\(name == "keys" ? "k" : "v")[\(i)]); \(r); })", at_)
        default: return nil
        }
    }

    func dictCall(_ obj: Expr, _ oc: String, _ ot: SType, _ name: String, _ args: [Arg]) throws -> (String, SType)? {
        guard case .dict(let kt, let vt) = ot else { return nil }
        func lv() throws -> String { try requireAssignable(obj); return try lvalue(obj).0 }
        switch name {
        case "removeValue":
            guard args.count == 1, args[0].label == "forKey" else { throw fail("use removeValue(forKey: key)") }
            let l = try lv(), k = newTmp("k"), i = newTmp("i"), opt = SType.optional(vt)
            return ("({ \(try decl(kt, k)) = \(try coerce(args[0].value, to: kt)); \(try ctype(opt)) _r = {0}; int \(i) = \(ot.mangled)_find(&\(l), \(k)); if (\(i) >= 0) { _r.has = 1; _r.v = \(l).v[\(i)]; \(ot.mangled)_remove(&\(l), \(k)); } _r; })", opt)
        case "removeAll":
            guard args.isEmpty else { throw fail("removeAll() takes no arguments") }
            return ("(\(try lv()).n = 0)", .void)
        case "updateValue":
            guard args.count == 2, args[1].label == "forKey" else { throw fail("use updateValue(value, forKey: key)") }
            let l = try lv()
            return ("\(ot.mangled)_set(&\(l), \(try coerce(args[1].value, to: kt)), \(try coerce(args[0].value, to: vt)))", .void)
        case "contains", "first", "map", "filter", "sorted", "forEach", "reduce":
            throw fail("a dictionary doesn't have '\(name)' here; loop over it with `for (key, value) in dict`, or use dict.keys / dict.values")
        default: return nil
        }
    }

    // MARK: Strings

    func stringProperty(_ bc: String, _ name: String) throws -> (String, SType)? {
        switch name {
        case "count": return ("((int)strlen((\(bc)).s))", .int)
        case "isEmpty": return ("((\(bc)).s[0] == 0)", .bool)
        default: return nil
        }
    }

    func stringCall(_ oc: String, _ name: String, _ args: [Arg]) throws -> (String, SType)? {
        switch name {
        case "uppercased": return ("ws_upper(\(oc))", .string)
        case "lowercased": return ("ws_lower(\(oc))", .string)
        case "hasPrefix", "hasSuffix", "contains":
            guard args.count == 1, args[0].label == nil else { throw fail("\(name) takes one string") }
            return ("ws_\(name == "contains" ? "contains" : name)(\(oc), \(try coerce(args[0].value, to: .string)))", .bool)
        default: return nil
        }
    }

    // MARK: Closures applied inline

    /// A closure (or operator, or function name) applied to `args`, expanded in place. `ret` is the
    /// type the caller needs (nil to infer from a single-expression body).
    func applyClosure(_ arg: Expr, _ ptypes: [SType], _ ret: SType?, _ args: [String]) throws -> (String, SType) {
        at(arg)
        switch arg.kind {
        case .opRef(let op):
            guard ptypes.count == 2, ptypes[0] == ptypes[1] else { throw fail("the operator \(op) needs two values of the same type here") }
            let t = ptypes[0]
            if ["<", ">", "<=", ">="].contains(op) {
                if t == .string { return ("(strcmp((\(args[0])).s, (\(args[1])).s) \(op) 0)", .bool) }
                guard t.isNumeric else { throw fail("operator \(op) can't be applied to \(t.name)") }
                return ("((\(args[0])) \(op) (\(args[1])))", .bool)
            }
            if op == "==" || op == "!=" { let eq = try equalityCode(args[0], args[1], t); return (op == "==" ? "(\(eq))" : "(!(\(eq)))", .bool) }
            return (try binaryCode(op, args[0], t, args[1], t), t)
        case .ident(let n):
            if let f = funcs[n] {
                guard f.params.map(\.type) == ptypes else { throw fail("'\(n)' doesn't take (\(ptypes.map(\.name).joined(separator: ", ")))") }
                return ("\(f.cName)(\(args.joined(separator: ", ")))", f.ret)
            }
            if let l = lookupLocal(n), case .fn(let ps, let r) = l.type {
                guard ps == ptypes else { throw fail("'\(n)' doesn't take (\(ptypes.map(\.name).joined(separator: ", ")))") }
                return ("({ \(try ctype(l.type)) _f = \(l.c); _f.f(_f.ctx\(args.map { ", " + $0 }.joined())); })", r)
            }
            throw fail("cannot find the function '\(n)'")
        case .closure(let c):
            return try inlineClosure(c, ptypes, ret, args)
        default:
            throw fail("expected a closure here")
        }
    }

    func inlineClosure(_ c: Closure, _ ptypes: [SType], _ ret: SType?, _ args: [String]) throws -> (String, SType) {
        let names: [String] = c.hasSignature ? c.params.map(\.name) : (0..<ptypes.count).map { "$\($0)" }
        guard names.count == ptypes.count else { throw fail("this closure takes \(names.count) parameter\(names.count == 1 ? "" : "s"), but \(ptypes.count) \(ptypes.count == 1 ? "is" : "are") provided here") }
        if c.hasSignature {
            for (i, p) in c.params.enumerated() {
                if let te = p.type, try resolve(te) != ptypes[i] { throw fail("closure parameter '\(p.name)' is \(try resolve(te).name), expected \(ptypes[i].name)") }
            }
        }
        let declared = try c.ret.map(resolve)
        let wanted = declared ?? ret
        ctx.scopes.append([:])
        defer { ctx.scopes.removeLast() }
        var decls = ""
        for (i, n) in names.enumerated() {
            let t = newTmp("p")
            decls += "\(try decl(ptypes[i], t)) = \(args[i]); "
            if n != "_" { ctx.scopes[ctx.scopes.count - 1][n] = Local(type: ptypes[i], c: t, isLet: true) }
        }
        let single: Expr? = { if c.body.count == 1, case .expr(let e) = c.body[0].kind { return e }; return nil }()
        if let e = single, wanted != .void {
            if let w = wanted { return ("({ \(decls)\(try coerce(e, to: w)); })", w) }
            let (vc, vt) = try expr(e, nil)
            return ("({ \(decls)\(vc); })", vt)
        }
        // Statement body.
        let label = newTmp("cl_end")
        guard let w = wanted else { throw fail("a closure with several statements needs an explicit result type, like { (x: Int) -> Int in ... }") }
        let frame = ClosureFrame(resultVar: w == .void ? nil : newTmp("rv"), label: label, ret: w)
        ctx.closures.append(frame)
        defer { ctx.closures.removeLast() }
        let body = try c.body.map { try stmt($0, indent: 0) }.joined().replacingOccurrences(of: "\n", with: " ")
        let endLabel = body.contains("goto \(label)") ? " \(label): ;" : ""   // unused labels are warnings in C
        if let rv = frame.resultVar { return ("({ \(try decl(w, rv)) = {0}; \(decls){ \(body) }\(endLabel) \(rv); })", w) }
        return ("({ \(decls){ \(body) }\(endLabel) })", .void)
    }

    // MARK: Function values

    /// An expression of function type for a closure, function name or operator.
    func functionValue(_ a: Expr, _ ps: [SType], _ r: SType, byReference: Bool = false) throws -> String {
        at(a)
        let ft = SType.fn(ps, r)
        switch a.kind {
        case .closure(let c): return try liftClosure(c, ps, r, expected: ft, byReference: byReference)
        case .ident(let n):
            if let l = lookupLocal(n), l.type == ft { return l.c }
            if let f = funcs[n] {
                guard f.params.map(\.type) == ps, f.ret == r else { throw fail("'\(n)' has the wrong type for this: expected \(ft.name)") }
                return try thunk(ps, r, expected: ft) { args in "\(f.cName)(\(args.joined(separator: ", ")))" }
            }
            throw fail("cannot find the function '\(n)'")
        case .opRef(let op):
            guard ps.count == 2, ps[0] == ps[1] else { throw fail("the operator \(op) needs two values of the same type here") }
            return try thunk(ps, r, expected: ft) { args in
                if ["<", ">", "<=", ">="].contains(op) { return "((\(args[0])) \(op) (\(args[1])))" }
                return (try? self.binaryCode(op, args[0], ps[0], args[1], ps[0])) ?? "0"
            }
        default:
            let (c, t) = try expr(a, ft)
            guard t == ft else { throw fail("cannot convert \(t.name) to \(ft.name)") }
            return c
        }
    }

    func thunk(_ ps: [SType], _ r: SType, expected ft: SType, body: ([String]) -> String) throws -> String {
        let id = newTmp("thunk")
        let names = ps.indices.map { "a\($0)" }
        var params = ["void *_c"]
        for (i, p) in ps.enumerated() { params.append(try decl(p, names[i])) }
        let call = body(names)
        let fn = "static \(try ctype(r)) \(id)(\(params.joined(separator: ", ")))"
        protos.append("\(fn);")
        bodies.append("\(fn) { (void)_c; \(r == .void ? "" : "return ")\(call); }")
        return "((\(try ctype(ft))){ \(id), 0 })"
    }

    func liftClosure(_ c: Closure, _ ps: [SType], _ r: SType, expected ft: SType, byReference: Bool = false) throws -> String {
        let names: [String] = c.hasSignature ? c.params.map(\.name) : (0..<ps.count).map { "$\($0)" }
        guard names.count == ps.count else { throw fail("this closure takes \(names.count) parameter\(names.count == 1 ? "" : "s"), but \(ps.count) \(ps.count == 1 ? "is" : "are") expected") }
        let parent = ctx
        let child = FnCtx()
        child.captureParent = parent
        child.captureByReference = byReference
        child.selfType = parent.selfType
        child.isMutating = true
        child.isStatic = parent.isStatic
        child.ret = (try c.ret.map(resolve)) ?? r
        let id = newTmp("cl")
        var params = ["void *_c"]
        for (i, n) in names.enumerated() {
            let pc = n == "_" ? newTmp("u") : (n.hasPrefix("$") ? "p\(n.dropFirst())" : cname(n))
            params.append(try decl(ps[i], pc))
            if n != "_" { child.scopes[0][n] = Local(type: ps[i], c: pc, isLet: true) }
        }
        ctx = child
        defer { ctx = parent }
        let body: String
        if child.ret != .void, c.body.count == 1, case .expr(let e) = c.body[0].kind { body = "    return \(try coerce(e, to: child.ret));\n" }
        else { body = try block(c.body, indent: 1) }
        ctx = parent

        // Captured variables travel by value in a small context struct.
        let caps = child.captured.sorted { $0.key < $1.key }
        let needsSelf = child.usedSelf
        var fields = ""
        for (n, l) in caps { fields += byReference ? "\(try ctype(l.type)) *c_\(n); " : "\(try decl(l.type, "c_\(n)")); " }
        if needsSelf, let st = parent.selfType { fields += "\(st.isClass ? "C_\(st.name) *" : "T_\(st.name) *")self; " }
        let fn = "static \(try ctype(child.ret)) \(id)(\(params.joined(separator: ", ")))"
        protos.append("\(fn);")
        var prologue = ""
        if !fields.isEmpty {
            typeDefs.append("typedef struct { \(fields)} \(id)_ctx;")
            prologue = "    \(id)_ctx *_cx = (\(id)_ctx *)_c; (void)_cx;\n"
            if needsSelf, let st = parent.selfType { prologue += "    \(st.isClass ? "C_\(st.name) *" : "T_\(st.name) *")self = _cx->self; (void)self;\n" }
        } else { prologue = "    (void)_c;\n" }
        bodies.append("\(fn) {\n\(prologue)\(body)}\n")

        if fields.isEmpty { return "((\(try ctype(ft))){ \(id), 0 })" }
        let cx = newTmp("cx")
        var assigns = ""
        for (n, l) in caps { assigns += byReference ? "\(cx)->c_\(n) = &\(l.c); " : "\(cx)->c_\(n) = \(l.c); " }
        if needsSelf { assigns += "\(cx)->self = self; " }
        return "({ \(id)_ctx *\(cx) = (\(id)_ctx *)wiiui_arena_alloc(sizeof(\(id)_ctx)); \(assigns)(\(try ctype(ft))){ \(id), \(cx) }; })"
    }

    func callFunctionValue(_ fc: String, _ ps: [SType], _ r: SType, _ args: [Arg]) throws -> (String, SType) {
        guard args.count == ps.count else { throw fail("this takes \(ps.count) argument\(ps.count == 1 ? "" : "s"), not \(args.count)") }
        var cs: [String] = []
        for (a, p) in zip(args, ps) {
            if a.label != nil { at(a.value); throw fail("function values take unlabeled arguments") }
            cs.append(try argument(a.value, to: p))
        }
        let f = newTmp("f")
        return ("({ \(try ctype(.fn(ps, r))) \(f) = \(fc); \(f).f(\(f).ctx\(cs.map { ", " + $0 }.joined())); })", r)
    }
}
