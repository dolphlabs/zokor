// A zokor service, minus the accept loop (that needs generic functions
// in slang; see the README's "Not yet" section). Everything else is
// here: state the framework knows nothing about, routes with parameters
// and a wildcard, middleware that can end a request, an after hook that
// runs either way, and failures that all look the same on the wire.
import "http";
import "zokor";

gc struct App {
    name: str,
    requests: int,
    token: str,
    errors: zokor.Registry,
}

impl App {
    fn errors_of(self: App) -> zokor.Registry {
        return self.errors;
    }
}

fn home(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "hello from " + c.state.name);
}

fn show_org(c: zokor.Ctx[App]) -> http.Response {
    if c.param("id") != "7" {
        return zokor.respond_with(c.state.errors_of(), "org.not_found",
                                  "no such organisation '" + c.param("id") + "'",
                                  c.request_id);
    }
    return zokor.ok_json("{\"org\":\"7\"}");
}

fn create_org(c: zokor.Ctx[App]) -> http.Response {
    let body = c.body_str();
    if len(body) == 0 {
        let fields = [zokor.field("name", "must not be empty")];
        return zokor.respond_fields(c.state.errors_of(), "validation_failed",
                                    fields, c.request_id);
    }
    return zokor.created("{\"created\":true}", "/orgs/7");
}

fn asset(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "file " + c.param("rest"));
}

fn search(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "q=" + c.query("q") +
                          " page=" + to_str(c.query_int("page", 1)));
}

fn require_token(c: zokor.Ctx[App]) -> opt[http.Response] {
    if c.route == "/" || c.route == "/search" || c.route == "/files/*rest" {
        return none;
    }
    if c.bearer() != c.state.token {
        return some(zokor.respond(c.state.errors_of(), "unauthorized",
                                  c.request_id));
    }
    return none;
}

fn count(c: zokor.Ctx[App], r: http.Response) -> http.Response {
    c.state.requests = c.state.requests + 1;
    r.headers["x-request-count"] = to_str(c.state.requests);
    return r;
}

fn req(method: str, p: str, token: str, body: str) -> http.Request {
    let h: map[str]str = {};
    if len(token) > 0 {
        h["authorization"] = "Bearer " + token;
    }
    return http.Request {
        method: method,
        path: p,
        version: "HTTP/1.1",
        headers: h,
        body: to_bytes(body)
    };
}

fn show(label: str, r: http.Response) {
    println(label + " -> " + to_str(r.status) + " " + to_str(r.body));
}

let cfg = zokor.load_config();
let reg = zokor.new_registry();
zokor.register(reg, "org.not_found", 404, "no such organisation");

let app = App {
    name: zokor.str_or(cfg, "SERVICE_NAME", "hello"),
    requests: 0,
    token: zokor.str_or(cfg, "API_TOKEN", "s3cret"),
    errors: reg
};

let r = zokor.Router[App] {
    routes: [],
    befores: [],
    afters: [],
    state: app,
    errors: reg,
    auto_options: true,
    auto_head: true
};

r.get("/", home);
r.get("/search", search);
r.get("/orgs/:id", show_org);
r.post("/orgs", create_org);
r.get("/files/*rest", asset);
r.before(require_token);
r.after(count);

for line in r.routes_list() {
    println("route " + line);
}
println("");

show("GET  /", r.serve(req("GET", "/", "", "")));
show("GET  /search?q=slang&page=2", r.serve(req("GET", "/search?q=slang&page=2", "", "")));
show("GET  /orgs/7", r.serve(req("GET", "/orgs/7", "s3cret", "")));
show("GET  /orgs/9", r.serve(req("GET", "/orgs/9", "s3cret", "")));
show("GET  /orgs/7 (no token)", r.serve(req("GET", "/orgs/7", "", "")));
show("POST /orgs (empty)", r.serve(req("POST", "/orgs", "s3cret", "")));
show("POST /orgs", r.serve(req("POST", "/orgs", "s3cret", "{\"name\":\"acme\"}")));
show("GET  /files/a/b.txt", r.serve(req("GET", "/files/a/b.txt", "", "")));
show("HEAD /", r.serve(req("HEAD", "/", "", "")));
show("DELETE /orgs/7", r.serve(req("DELETE", "/orgs/7", "s3cret", "")));
show("GET  /nope", r.serve(req("GET", "/nope", "s3cret", "")));
println("requests=" + to_str(app.requests));
