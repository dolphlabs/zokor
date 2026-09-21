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
}

pub gc struct Route[S] {
    method: Method,
    pattern: str,
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

// An application builds its router with a struct literal, because a
// constructor would have to be a generic FUNCTION and slang does not
// have those yet:
//
//     let r = zokor.Router[App] {
//         routes: [], befores: [], afters: [], state: app,
//         errors: zokor.new_registry(), auto_options: true, auto_head: true
//     };

impl Router[S] {
    // Every method goes through here, including the ones with their own
    // helper below, so a pattern is split exactly once and the rules
    // about `:params` and `*rest` live in one place.
    pub fn handle(self: Router[S], method: Method, pattern: str,
                  h: fn(Ctx[S]) -> http.Response) -> int {
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
    fn match_segs(self: Router[S], r: Route[S], segs: [str],
                  params: map[str]str) -> bool {
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
                let rest = "";
                let j = i;
                while j < len(segs) {
                    if j > i {
                        rest = rest + "/";
                    }
                    rest = rest + segs[j];
                    j = j + 1;
                }
                params[r.names[i]] = rest;
                return true;
            }
            if len(r.names[i]) > 0 {
                params[r.names[i]] = segs[i];
            } else {
                if r.segs[i] != segs[i] {
                    return false;
                }
            }
            i = i + 1;
        }
        return true;
    }

    // The methods registered for a path, for `Allow` on a 405 and for
    // an automatic OPTIONS.
    pub fn allowed(self: Router[S], p: str) -> [Method] {
        let segs = path.split(path.strip_query(p));
        let out: [Method] = [];
        let i = 0;
        while i < len(self.routes) {
            let probe: map[str]str = {};
            if self.match_segs(self.routes[i], segs, probe) {
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
            let uc = Ctx[S] {
                state: self.state,
                req: req,
                params: unknown,
                route: "",
                request_id: request_id
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
            let params: map[str]str = {};
            if !self.match_segs(r, segs, params) {
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
            let c = Ctx[S] {
                state: self.state,
                req: req,
                params: params,
                route: r.pattern,
                request_id: request_id
            };
            let resp = self.run(c, r.handler);
            if head_of_get && r.method == Method.GET {
                resp.body = to_bytes("");
            }
            return resp;
        }

        let none_params: map[str]str = {};
        let c = Ctx[S] {
            state: self.state,
            req: req,
            params: none_params,
            route: "",
            request_id: request_id
        };
        if !path_seen {
            return self.finish(c, respond(self.errors, "not_found", request_id));
        }
        let allow = self.allowed(p);
        if self.auto_options && method == Method.OPTIONS {
            let ok_resp = http.Response {
                status: 204,
                status_text: "No Content",
                headers: allow_headers(allow),
                body: to_bytes("")
            };
            return self.finish(c, ok_resp);
        }
        let resp = respond(self.errors, "method_not_allowed", request_id);
        resp.headers["allow"] = join_methods(allow);
        return self.finish(c, resp);
    }

    fn run(self: Router[S], c: Ctx[S],
           h: fn(Ctx[S]) -> http.Response) -> http.Response {
        let i = 0;
        while i < len(self.befores) {
            let b = self.befores[i];
            let stop = b(c);
            guard let resp = stop else {
                i = i + 1;
                continue;
            }
            return self.finish(c, resp);
        }
        return self.finish(c, h(c));
    }

    fn finish(self: Router[S], c: Ctx[S],
              resp: http.Response) -> http.Response {
        let out = resp;
        if len(c.request_id) > 0 && !has(out.headers, "x-request-id") {
            out.headers["x-request-id"] = c.request_id;
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

fn allow_headers(allow: [Method]) -> map[str]str {
    let h: map[str]str = {};
    h["allow"] = join_methods(allow);
    h["content-length"] = "0";
    return h;
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
