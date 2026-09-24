// The router: a request goes in, a response comes out, and the
// application's own state comes with it.
//
// `Router[S]` is generic over S, the application's state, because a
// framework cannot know what a service needs to answer a request -- a
// database pool, its configuration, its services. Without that, the
// only way to reach them from a handler is to pass each as a separate
// parameter: a real control plane ended up with a twelve-parameter
// `dispatch`, widened again by every new service. Here it is one value,
// declared by the application, reaching every handler through `Ctx[S]`.
//
// Matching is done on segments, split once per request, against
// patterns split once at registration. No regular expressions, no
// per-request compilation, and a literal segment costs a comparison.

import "http";
import "internal/path";
import "strings";
import "json";
import "builder";

// The HTTP methods, as a closed set. A service names `zokor.Method.GET`,
// not "GET": a typo is then a compile error rather than a route that
// silently never matches, and `r.handle(m, ...)` takes a value the
// compiler has already checked. The variant names are exactly the
// tokens on the wire, so `to_str` and `from_str` are the conversion.
pub enum Method {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
    TRACE,
    CONNECT,
}

pub gc struct Ctx[S] {
    state: S,
    req: http.Request,
    // Path parameters by the name in the pattern: `/orgs/:id` binds
    // "id". Empty for a pattern without any.
    params: map[str]str,
    // The PATTERN that matched, not the path: `/orgs/7` and `/orgs/9`
    // report as one route, so metrics and logs stay one series per
    // route instead of one per id.
    route: str,
    // Set by the server for each connection; carried into logs and
    // onto every error response.
    request_id: str,
    // What middleware hands to the handler. Authentication resolves a
    // token and puts the user here; a tenant resolver puts the tenant
    // here. Without it a `before` can only stop a request, never
    // contribute to it -- which is how services end up re-doing the
    // same lookup in every handler.
    locals: map[str]str,
    // The router's own registry, carried here so a helper like `dto`
    // can answer a failure without asking the application's state to
    // also hold one by convention.
    errors: Registry,
}

pub gc struct Route[S] {
    method: Method,
    pattern: str,
    // Middleware for THIS route: whatever its group carried when it was
    // registered, plus anything added to the route itself. Router-wide
    // hooks run first, then these.
    befores: [fn(Ctx[S]) -> opt[http.Response]],
    afters: [fn(Ctx[S], http.Response) -> http.Response],
    segs: [str],
    // Precomputed so matching never inspects a segment's first byte:
    // "" for a literal, the name for `:id`, and `wild` for a `*rest`
    // tail, which matches the rest of the path.
    names: [str],
    wild: int,
    handler: fn(Ctx[S]) -> http.Response,
}

// A `before` runs ahead of the handler and may end the request by
// returning a response; `none` carries on. An `after` sees whatever
// response was produced and returns the one to send, so logging,
// headers and envelopes are written once rather than in every handler.
//
// slang has no closures, so these are top-level functions -- which is
// why they take the whole Ctx instead of captured state.
pub gc struct Router[S] {
    routes: [Route[S]],
    befores: [fn(Ctx[S]) -> opt[http.Response]],
    afters: [fn(Ctx[S], http.Response) -> http.Response],
    state: S,
    errors: Registry,
    // OPTIONS and HEAD answered by the router when no route claims
    // them. On by default; both are what a correct HTTP server does.
    auto_options: bool,
    auto_head: bool,
}

// An application builds its router from its state alone; everything else
// starts empty or at the default a correct server should have. This used
// to be a seven-field struct literal every service wrote out by hand --
// `new_router` needed a generic function, which slang did not have until
// generics PR 3.
pub fn new_router[S](state: S) -> Router[S] {
    let no_routes: [Route[S]] = [];
    let no_befores: [fn(Ctx[S]) -> opt[http.Response]] = [];
    let no_afters: [fn(Ctx[S], http.Response) -> http.Response] = [];
    return Router[S] {
        routes: no_routes,
        befores: no_befores,
        afters: no_afters,
        state: state,
        errors: new_registry(),
        auto_options: true,
        auto_head: true
    };
}

// The function-call equivalent of `r.group(prefix)`, for a service that
// wants its setup to read as a list of constructors rather than a mix of
// functions and methods:
//
//     let api = zokor.new_group(r, "/api");
//
// Identical to the method; kept as a thin alias so both styles exist and
// neither is the "real" one.
pub fn new_group[S](r: Router[S], prefix: str) -> Group[S] {
    return r.group(prefix);
}

impl Router[S] {
    // Every method goes through here, including the ones with their own
    // helper below, so a pattern is split exactly once and the rules
    // about `:params` and `*rest` live in one place.
    pub fn handle(self: Router[S], method: Method, pattern: str,
                  h: fn(Ctx[S]) -> http.Response) -> int {
        let no_before: [fn(Ctx[S]) -> opt[http.Response]] = [];
        let no_after: [fn(Ctx[S], http.Response) -> http.Response] = [];
        return self.handle_with(method, pattern, h, no_before, no_after);
    }

    // The one registration path: a pattern is split exactly once, and
    // the rules about `:params` and `*rest` live here alone.
    pub fn handle_with(self: Router[S], method: Method, pattern: str,
                       h: fn(Ctx[S]) -> http.Response,
                       befores: [fn(Ctx[S]) -> opt[http.Response]],
                       afters: [fn(Ctx[S], http.Response) -> http.Response]) -> int {
        let segs = path.split(pattern);
        let names: [str] = [];
        let wild = -1;
        let i = 0;
        while i < len(segs) {
            let w = path.wildcard_name(segs[i]);
            if len(w) > 0 {
                wild = i;
                push(names, w);
            } else {
                push(names, path.param_name(segs[i]));
            }
            i = i + 1;
        }
        push(self.routes, Route[S] {
            method: method,
            pattern: pattern,
            befores: befores,
            afters: afters,
            segs: segs,
            names: names,
            wild: wild,
            handler: h
        });
        return len(self.routes);
    }

    // The full set of HTTP methods, so no service has to fall back to
    // `handle` with a string for anything standard.
    pub fn get(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.GET, p, h);
    }
    pub fn head(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.HEAD, p, h);
    }
    pub fn post(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.POST, p, h);
    }
    pub fn put(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.PUT, p, h);
    }
    pub fn patch(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.PATCH, p, h);
    }
    pub fn delete(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.DELETE, p, h);
    }
    pub fn options(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.OPTIONS, p, h);
    }
    pub fn trace(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.TRACE, p, h);
    }
    pub fn connect(self: Router[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.CONNECT, p, h);
    }

    // One handler for several methods on one pattern.
    pub fn any(self: Router[S], methods: [Method], p: str,
               h: fn(Ctx[S]) -> http.Response) -> int {
        let i = 0;
        while i < len(methods) {
            self.handle(methods[i], p, h);
            i = i + 1;
        }
        return len(self.routes);
    }

    // A prefix with its own middleware. Router-wide hooks still run
    // first, for everything.
    pub fn group(self: Router[S], prefix: str) -> Group[S] {
        let bs: [fn(Ctx[S]) -> opt[http.Response]] = [];
        let as_: [fn(Ctx[S], http.Response) -> http.Response] = [];
        return Group[S] {
            router: self,
            prefix: prefix,
            befores: bs,
            afters: as_
        };
    }

    // Middleware for one route, which is the other half of the same
    // need: `r.guarded(Method.DELETE, "/orgs/:id", drop, [require_admin])`.
    pub fn guarded(self: Router[S], method: Method, pattern: str,
                   h: fn(Ctx[S]) -> http.Response,
                   befores: [fn(Ctx[S]) -> opt[http.Response]]) -> int {
        let no_after: [fn(Ctx[S], http.Response) -> http.Response] = [];
        return self.handle_with(method, pattern, h, befores, no_after);
    }

    pub fn before(self: Router[S], f: fn(Ctx[S]) -> opt[http.Response]) -> int {
        push(self.befores, f);
        return len(self.befores);
    }

    pub fn after(self: Router[S], f: fn(Ctx[S], http.Response) -> http.Response) -> int {
        push(self.afters, f);
        return len(self.afters);
    }

    // "METHOD /pattern" per route, in registration order: for a boot
    // log, for `zokor check`, and for a test that pins down the surface
    // a service exposes.
    pub fn routes_list(self: Router[S]) -> [str] {
        let out: [str] = [];
        let i = 0;
        while i < len(self.routes) {
            push(out, to_str(self.routes[i].method) + " " +
                      self.routes[i].pattern);
            i = i + 1;
        }
        return out;
    }

    // Does this route's pattern match these segments? Binds parameters
    // into `params` only on a match, so a near miss costs no map.
    //
    // Two entry points because the 405/OPTIONS path (`allowed`) only
    // needs to know WHETHER a route matches, while dispatch needs the
    // bindings: `match_only` skips the params map entirely (no alloc,
    // no join) and `match_segs` binds on success. One shape check, not
    // two -- `match_only` is the shape check, `match_segs` is the shape
    // check plus the bindings.
    fn match_only(self: Router[S], r: Route[S], segs: [str]) -> bool {
        if r.wild >= 0 {
            if len(segs) < r.wild {
                return false;
            }
        } else {
            if len(r.segs) != len(segs) {
                return false;
            }
        }
        let i = 0;
        while i < len(r.segs) {
            if i == r.wild {
                return true;
            }
            if len(r.names[i]) == 0 && r.segs[i] != segs[i] {
                return false;
            }
            i = i + 1;
        }
        return true;
    }

    fn match_segs(self: Router[S], r: Route[S], segs: [str],
                  params: map[str]str) -> bool {
        if !self.match_only(r, segs) {
            return false;
        }
        let i = 0;
        while i < len(r.segs) {
            if i == r.wild {
                // one join instead of one concatenation per segment
                params[r.names[i]] = strings.join(segs[i..len(segs)], "/");
                return true;
            }
            if len(r.names[i]) > 0 {
                params[r.names[i]] = segs[i];
            }
            i = i + 1;
        }
        return true;
    }

    // The methods registered for a path, for `Allow` on a 405 and for
    // an automatic OPTIONS. Match-only: no params map per route, which
    // used to cost one map (plus the wild join) per route per 405 --
    // pure overhead on a path that answers without bindings.
    pub fn allowed(self: Router[S], p: str) -> [Method] {
        let segs = path.split(path.strip_query(p));
        let out: [Method] = [];
        let i = 0;
        while i < len(self.routes) {
            if self.match_only(self.routes[i], segs) {
                let m = self.routes[i].method;
                let seen = false;
                let j = 0;
                while j < len(out) {
                    if out[j] == m {
                        seen = true;
                    }
                    j = j + 1;
                }
                if !seen {
                    push(out, m);
                }
            }
            i = i + 1;
        }
        if self.auto_head {
            let has_get = false;
            let has_head = false;
            let k = 0;
            while k < len(out) {
                if out[k] == Method.GET { has_get = true; }
                if out[k] == Method.HEAD { has_head = true; }
                k = k + 1;
            }
            if has_get && !has_head {
                push(out, Method.HEAD);
            }
        }
        if len(out) > 0 && self.auto_options {
            let has_opt = false;
            let k2 = 0;
            while k2 < len(out) {
                if out[k2] == Method.OPTIONS { has_opt = true; }
                k2 = k2 + 1;
            }
            if !has_opt {
                push(out, Method.OPTIONS);
            }
        }
        return out;
    }

    // Dispatch: befores, the handler, then afters -- and the afters run
    // even when a before ended the request, so a logging or header hook
    // cannot be skipped by a short circuit.
    pub fn serve(self: Router[S], req: http.Request) -> http.Response {
        return self.serve_id(req, "");
    }

    pub fn serve_id(self: Router[S], req: http.Request,
                    request_id: str) -> http.Response {
        let p = path.strip_query(req.path);
        let segs = path.split(p);
        // An unknown verb cannot match any route, and is not a 404: the
        // path may well exist. 501 is what it is.
        let parsed = Method.from_str(req.method);
        guard let method = parsed else {
            let unknown: map[str]str = {};
            let unknown_locals: map[str]str = {};
            let uc = Ctx[S] {
                state: self.state,
                req: req,
                params: unknown,
                route: "",
                request_id: request_id,
                locals: unknown_locals,
                errors: self.errors
            };
            return self.finish(uc, respond(self.errors, "not_implemented",
                                           request_id));
        }
        // A HEAD with no HEAD route is served by the GET one, and the
        // body dropped after the handler and the hooks have run -- so
        // the headers a client gets are the ones it would get from GET.
        let head_of_get = false;
        if self.auto_head && method == Method.HEAD {
            head_of_get = true;
        }
        let path_seen = false;
        let i = 0;
        while i < len(self.routes) {
            let r = self.routes[i];
            // Shape first, bindings after: a near miss costs no map, and
            // a path hit with the wrong method costs no map either --
            // the params map is built only when this route will actually
            // run. On a two-route bench router that saves one map per
            // request; on a fifty-route service it saves fifty.
            if !self.match_only(r, segs) {
                i = i + 1;
                continue;
            }
            path_seen = true;
            let m = r.method == method;
            if !m && head_of_get && r.method == Method.GET {
                m = true;
            }
            if !m {
                i = i + 1;
                continue;
            }
            let params: map[str]str = {};
            self.match_segs(r, segs, params);
            let locals: map[str]str = {};
            let c = Ctx[S] {
                state: self.state,
                req: req,
                params: params,
                route: r.pattern,
                request_id: request_id,
                locals: locals,
                errors: self.errors
            };
            let resp = self.run(c, r);
            if head_of_get && r.method == Method.GET {
                resp.body = to_bytes("");
            }
            return resp;
        }

        let none_params: map[str]str = {};
        let no_locals: map[str]str = {};
        let c = Ctx[S] {
            state: self.state,
            req: req,
            params: none_params,
            route: "",
            request_id: request_id,
            locals: no_locals,
            errors: self.errors
        };
        if !path_seen {
            return self.finish(c, respond(self.errors, "not_found", request_id));
        }
        let allow = self.allowed(p);
        if self.auto_options && method == Method.OPTIONS {
            let none_extra: [str] = allow_extra(allow);
            let ok_resp = http.Response {
                status: 204,
                status_text: "No Content",
                content_type: "",
                location: "",
                extra: none_extra,
                body: to_bytes("")
            };
            return self.finish(c, ok_resp);
        }
        let resp = respond(self.errors, "method_not_allowed", request_id);
        resp = http.with_header(resp, "allow", join_methods(allow));
        return self.finish(c, resp);
    }

    // Router-wide `before`s, then the route's own, then the handler.
    // A `before` that returns a response stops the rest -- but the
    // `after`s still run, so a logging or header hook cannot be skipped
    // by a short circuit.
    fn run(self: Router[S], c: Ctx[S], r: Route[S]) -> http.Response {
        let i = 0;
        while i < len(self.befores) {
            let b = self.befores[i];
            let stop = b(c);
            guard let resp = stop else {
                i = i + 1;
                continue;
            }
            return self.finish_route(c, r, resp);
        }
        let j = 0;
        while j < len(r.befores) {
            let rb = r.befores[j];
            let stop2 = rb(c);
            guard let resp2 = stop2 else {
                j = j + 1;
                continue;
            }
            return self.finish_route(c, r, resp2);
        }
        let h = r.handler;
        return self.finish_route(c, r, h(c));
    }

    // The route's own `after`s run first, then the router-wide ones:
    // the nearest hook to the handler is the innermost.
    fn finish_route(self: Router[S], c: Ctx[S], r: Route[S],
                    resp: http.Response) -> http.Response {
        let out = resp;
        let i = 0;
        while i < len(r.afters) {
            let a = r.afters[i];
            out = a(c, out);
            i = i + 1;
        }
        return self.finish(c, out);
    }

    fn finish(self: Router[S], c: Ctx[S],
              resp: http.Response) -> http.Response {
        let out = resp;
        if len(c.request_id) > 0 && !http.has_resp_header(out, "x-request-id") {
            out = http.with_header(out, "x-request-id", c.request_id);
        }
        let i = 0;
        while i < len(self.afters) {
            let a = self.afters[i];
            out = a(c, out);
            i = i + 1;
        }
        return out;
    }

    // The registry's codes, rendered with this request's id. A handler
    // reports a failure with `r.fail(c, "org.not_found")`, never by
    // writing JSON.
    pub fn fail(self: Router[S], c: Ctx[S], code: str) -> http.Response {
        return respond(self.errors, code, c.request_id);
    }

    pub fn fail_with(self: Router[S], c: Ctx[S], code: str,
                     detail: str) -> http.Response {
        return respond_with(self.errors, code, detail, c.request_id);
    }

    pub fn fail_fields(self: Router[S], c: Ctx[S], code: str,
                       fields: [FieldError]) -> http.Response {
        return respond_fields(self.errors, code, fields, c.request_id);
    }
}

pub fn join_methods(ms: [Method]) -> str {
    let out = "";
    let i = 0;
    while i < len(ms) {
        if i > 0 {
            out = out + ", ";
        }
        out = out + to_str(ms[i]);
        i = i + 1;
    }
    return out;
}

fn allow_extra(allow: [Method]) -> [str] {
    let out: [str] = [];
    push(out, "allow: " + join_methods(allow));
    return out;
}


// A prefix and the middleware that goes with it.
//
// Without groups, middleware is either global or written into the
// handler -- which is how a service ends up with `if path == "/health"
// || path == "/login"` at the top of its authentication hook, a list
// that is wrong the moment somebody adds a route. A group says it once:
//
//     let api = r.group("/api/v1");
//     api.before(require_token);           // everything below is guarded
//     api.get("/orgs/:id", show_org);
//     api.post("/orgs", create_org);
//
//     let admin = api.group("/admin");     // groups nest: /api/v1/admin
//     admin.before(require_admin);
//     admin.delete("/orgs/:id", drop_org);
//
// Middleware applies to the routes registered AFTER it, on that group,
// which is the rule every other framework uses and the only one that
// reads top to bottom.
pub gc struct Group[S] {
    router: Router[S],
    prefix: str,
    befores: [fn(Ctx[S]) -> opt[http.Response]],
    afters: [fn(Ctx[S], http.Response) -> http.Response],
}

fn join_prefix(a: str, b: str) -> str {
    let left = a;
    let lb = to_bytes(left);
    if len(lb) > 0 && lb[len(lb) - 1] == 47 {
        left = to_str(lb[0..len(lb) - 1]);
    }
    let right = b;
    let rb = to_bytes(right);
    if len(rb) == 0 {
        return left;
    }
    if rb[0] != 47 {
        right = "/" + right;
    }
    return left + right;
}

impl Group[S] {
    // A route takes a COPY of the middleware as it stands when it is
    // registered, so adding another hook later cannot silently change a
    // route that already exists. (Methods, not functions: a generic
    // function is not a thing slang has yet.)
    fn copied_befores(self: Group[S]) -> [fn(Ctx[S]) -> opt[http.Response]] {
        let out: [fn(Ctx[S]) -> opt[http.Response]] = [];
        let i = 0;
        while i < len(self.befores) {
            push(out, self.befores[i]);
            i = i + 1;
        }
        return out;
    }

    fn copied_afters(self: Group[S]) -> [fn(Ctx[S], http.Response) -> http.Response] {
        let out: [fn(Ctx[S], http.Response) -> http.Response] = [];
        let i = 0;
        while i < len(self.afters) {
            push(out, self.afters[i]);
            i = i + 1;
        }
        return out;
    }

    // A group inside this one: the prefixes join and the middleware
    // accumulates.
    pub fn group(self: Group[S], prefix: str) -> Group[S] {
        return Group[S] {
            router: self.router,
            prefix: join_prefix(self.prefix, prefix),
            befores: self.copied_befores(),
            afters: self.copied_afters()
        };
    }

    pub fn before(self: Group[S], f: fn(Ctx[S]) -> opt[http.Response]) -> int {
        push(self.befores, f);
        return len(self.befores);
    }

    pub fn after(self: Group[S], f: fn(Ctx[S], http.Response) -> http.Response) -> int {
        push(self.afters, f);
        return len(self.afters);
    }

    pub fn handle(self: Group[S], method: Method, pattern: str,
                  h: fn(Ctx[S]) -> http.Response) -> int {
        return self.router.handle_with(method,
                                       join_prefix(self.prefix, pattern), h,
                                       self.copied_befores(),
                                       self.copied_afters());
    }

    pub fn get(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.GET, p, h);
    }
    pub fn head(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.HEAD, p, h);
    }
    pub fn post(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.POST, p, h);
    }
    pub fn put(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.PUT, p, h);
    }
    pub fn patch(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.PATCH, p, h);
    }
    pub fn delete(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.DELETE, p, h);
    }
    pub fn options(self: Group[S], p: str, h: fn(Ctx[S]) -> http.Response) -> int {
        return self.handle(Method.OPTIONS, p, h);
    }
}

impl Ctx[S] {
    pub fn param(self: Ctx[S], name: str) -> str {
        if has(self.params, name) {
            return self.params[name];
        }
        return "";
    }

    pub fn param_int(self: Ctx[S], name: str, fallback: int) -> int {
        return to_int(self.param(name)) ?? fallback;
    }

    pub fn header(self: Ctx[S], name: str) -> str {
        return http.header(self.req, name) ?? "";
    }

    // What a `before` resolved, read by the handler: the user a token
    // belongs to, the tenant a subdomain names, the plan a customer is
    // on. The lookup happens once, at the edge, not in every handler.
    pub fn set_local(self: Ctx[S], key: str, v: str) -> int {
        self.locals[key] = v;
        return len(self.locals);
    }

    pub fn local(self: Ctx[S], key: str) -> str {
        if has(self.locals, key) {
            return self.locals[key];
        }
        return "";
    }

    pub fn has_local(self: Ctx[S], key: str) -> bool {
        return has(self.locals, key);
    }

    pub fn body_str(self: Ctx[S]) -> str {
        return to_str(self.req.body);
    }

    pub fn body_bytes(self: Ctx[S]) -> bytes {
        return self.req.body;
    }

    // The verb as a checked value. An unknown one never reaches a
    // handler (serve answers 501), so this cannot fail here.
    pub fn method(self: Ctx[S]) -> Method {
        return Method.from_str(self.req.method) ?? Method.GET;
    }

    // The verb exactly as the client sent it, for logs.
    pub fn method_str(self: Ctx[S]) -> str {
        return self.req.method;
    }

    pub fn path(self: Ctx[S]) -> str {
        return path.strip_query(self.req.path);
    }

    // One query parameter, percent-decoded, or "".
    pub fn query(self: Ctx[S], name: str) -> str {
        return path.query_get(path.query_of(self.req.path), name);
    }

    pub fn query_int(self: Ctx[S], name: str, fallback: int) -> int {
        let v = self.query(name);
        if len(v) == 0 {
            return fallback;
        }
        return to_int(v) ?? fallback;
    }

    // The bearer token without its scheme, or "".
    pub fn bearer(self: Ctx[S]) -> str {
        let h = self.header("authorization");
        let b = to_bytes(h);
        if len(b) < 8 {
            return "";
        }
        if to_str(b[0..7]) != "Bearer " {
            return "";
        }
        return to_str(b[7..len(b)]);
    }

    pub fn content_type(self: Ctx[S]) -> str {
        return self.header("content-type");
    }

    // The body as a JSON value, for a shape you have not declared.
    // A declared one goes through slang's `json.decode` with your
    // struct as the annotation, and `decode_failed` renders its error.
    pub fn json_body(self: Ctx[S]) -> result[Json, FormError] {
        return parse_body(self.content_type(), self.req.body);
    }

    // The multipart form this request carries, under the caller's
    // rules. The failure names a registered code, so a handler reports
    // it the same way it reports anything else.
    pub fn form(self: Ctx[S], rules: UploadRules) -> result[Form, FormError] {
        return parse_form(self.content_type(), self.req.body, rules);
    }

    // The same, refused unless the request is a POST/PUT/PATCH: a body
    // on a GET is a client doing something strange.
    pub fn upload(self: Ctx[S], rules: UploadRules) -> result[Form, FormError] {
        let m = self.method();
        if m != Method.POST && m != Method.PUT && m != Method.PATCH {
            return err(FormError {
                code: "method_not_allowed",
                detail: "a file upload must be POST, PUT or PATCH"
            });
        }
        return self.form(rules);
    }

    pub fn wants_close(self: Ctx[S]) -> bool {
        return http.wants_close(self.req);
    }
}

// The body decoded into a declared shape, in one call: the wire's
// camelCase keys become the struct's snake_case fields (slang's
// `json.decode`, same as writing it out by hand), and a decode failure
// is already the response to return, rendered through `decode_failed`
// against this router's own registry --
//
//     let r: result[CreateOrg, http.Response] = zokor.dto(c);
//     guard let body = r else let resp = err_of(r) {
//         return resp;
//     }
//
// instead of decoding, naming the registry, and rendering the failure
// separately in every handler that takes a body. A plain function, not
// a method on `Ctx[S]`: a generic method cannot yet declare a type
// parameter of its own beyond the struct's (`T` here, next to `Ctx`'s
// own `S`) -- see "Generic structs" in slang's README.
pub fn dto[S, T](c: Ctx[S]) -> result[T, http.Response] {
    let r: result[T, str] = json.decode(snake_keys(c.body_str()));
    guard let v = r else let e = err_of(r) {
        return err(decode_failed(c.errors, e, c.request_id));
    }
    return ok(v);
}

// A query value that reads as a number or `true`/`false` is written
// into the object `query_as` builds bare; anything else is a quoted
// string. slang has no reflection, so there is no way to ask T what
// type each field wants and convert to just that -- this is the same
// trade `dto` doesn't have to make (a body already arrives typed), and
// it covers the common query shapes (str, int, float, bool fields)
// without one.
fn query_json_value(v: str) -> str {
    if v == "true" || v == "false" {
        return v;
    }
    let ir: result[int, str] = to_int(v);
    guard let _n = ir else {
        let fr: result[float, str] = to_float(v);
        guard let _f = fr else {
            return quote(v);
        }
        return v;
    }
    return v;
}

fn query_json(qs: str) -> str {
    let sb = builder.new_str();
    sb.write("{");
    let first = true;
    for k, v in path.query_all(qs) {
        if !first {
            sb.write(",");
        }
        first = false;
        sb.write(quote(k));
        sb.write(":");
        sb.write(query_json_value(v));
    }
    sb.write("}");
    return sb.finish();
}

// The query string bound into a declared shape, in one call, with the
// same field-level errors a bad body gets --
//
//     let r: result[Search, http.Response] = zokor.query_as(c);
//     guard let q = r else let resp = err_of(r) {
//         return resp;
//     }
//
// A missing field is an error the same way it is for `dto` unless T
// declares it `opt[...]`; there is no fallback value to reach for
// silently. A plain function for the same reason `dto` is one.
pub fn query_as[S, T](c: Ctx[S]) -> result[T, http.Response] {
    let r: result[T, str] = json.decode(snake_keys(query_json(path.query_of(c.req.path))));
    guard let v = r else let e = err_of(r) {
        return err(decode_failed(c.errors, e, c.request_id));
    }
    return ok(v);
}
