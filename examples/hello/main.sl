// A zokor service.
//
// Read the "the service" section below: that is the whole API. The
// section after it fabricates requests and prints the responses,
// because zokor has no accept loop yet (it needs generic functions in
// slang -- see the README). When `listen_and_serve` lands, that second
// section is deleted and nothing in the first one changes.
import "http";
import "json";
import "../../src" as zokor;

// ---------------------------------------------------------------- //
// the service                                                        //
// ---------------------------------------------------------------- //

gc struct App {
    name: str,
    requests: int,
    token: str,
    errors: zokor.Registry,
}

fn home(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "hello from " + c.state.name);
}

fn search(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "q=" + c.query("q") +
                           " page=" + to_str(c.query_int("page", 1)));
}

fn show_org(c: zokor.Ctx[App]) -> http.Response {
    if c.param("id") != "7" {
        return zokor.respond_with(c.state.errors, "org.not_found",
                                  "no such organisation '" + c.param("id") + "'",
                                  c.request_id);
    }
    return zokor.ok_json("{\"org\":\"7\"}");
}

// A DTO: a declared shape. slang's own json.decode fills it, a missing
// field is an error rather than a silent zero, and `decode_failed`
// puts the field it names into the standard envelope.
gc struct CreateOrg {
    name: str,
    plan: str,
    seats: i32,
    website: opt[str],
}

fn create_org(c: zokor.Ctx[App]) -> http.Response {
    // the wire is camelCase, the struct is snake_case: no tags needed
    let r: result[CreateOrg, str] = json.decode(zokor.snake_keys(c.body_str()));
    guard let dto = r else let e = err_of(r) {
        return zokor.decode_failed(c.state.errors, e, c.request_id);
    }

    // types are checked by the decoder; VALUES are checked here, and
    // every problem is reported at once
    let v = zokor.checker();
    if len(dto.name) == 0 {
        v.note("name", "must not be empty");
    }
    if dto.seats < 1 || dto.seats > 500 {
        v.note("seats", "must be between 1 and 500");
    }
    if dto.plan != "free" && dto.plan != "pro" {
        v.note("plan", "must be one of: free, pro");
    }
    if v.failed() {
        return zokor.respond_fields(c.state.errors, "validation_failed",
                                    v.fields, c.request_id);
    }

    let body = zokor.jobj()
        .set_str("id", "org_7")
        .set_str("name", dto.name)
        .set_str("plan", dto.plan)
        .set_int("seats", dto.seats as int)
        .set_opt_str("website", dto.website);
    return zokor.created(zokor.camel_keys(body.render()), "/orgs/org_7");
}

// A shape nobody declared: a webhook whose fields belong to somebody
// else. `json_body` walks it without a struct.
fn webhook(c: zokor.Ctx[App]) -> http.Response {
    let r = c.json_body();
    guard let body = r else let e = err_of(r) {
        return zokor.respond_with(c.state.errors, e.code, e.detail,
                                  c.request_id);
    }
    let event = body.get("type").str_or("unknown");
    let city = body.path("data.customer.address.city").str_or("nowhere");
    let first_item = body.path("data.items.0.sku").str_or("none");
    return zokor.ok_json(zokor.jobj()
        .set_str("event", event)
        .set_str("city", city)
        .set_str("first_item", first_item)
        .set_int("item_count", body.path("data.items").size())
        .render());
}

fn asset(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "file " + c.param("rest"));
}

// An upload: the rules say what is acceptable, and anything else comes
// back as a registered failure rather than reaching this handler.
fn upload_avatar(c: zokor.Ctx[App]) -> http.Response {
    let rules = zokor.with_max_file_bytes(
        zokor.uploads_allowing(["image/png", "image/jpeg"]), 1048576);
    let r = c.upload(rules);
    guard let form = r else let e = err_of(r) {
        return zokor.respond_with(c.state.errors, e.code, e.detail,
                                  c.request_id);
    }
    guard let avatar = zokor.file(form, "avatar") else {
        return zokor.respond_with(c.state.errors, "validation_failed",
                                  "no file was posted under 'avatar'",
                                  c.request_id);
    }
    // avatar.filename is already safe to use as one path segment
    return zokor.ok_json("{\"stored\":\"" + avatar.filename +
                         "\",\"type\":\"" + avatar.content_type +
                         "\",\"bytes\":" + to_str(len(avatar.data)) +
                         ",\"title\":\"" + zokor.value(form, "title") + "\"}");
}

// Middleware. A `before` may end the request; an `after` sees whatever
// response came back, including one a before produced.
fn require_token(c: zokor.Ctx[App]) -> opt[http.Response] {
    if c.route == "/" || c.route == "/search" || c.route == "/files/*rest" {
        return none;
    }
    if c.bearer() != c.state.token {
        return some(zokor.respond(c.state.errors, "unauthorized",
                                  c.request_id));
    }
    return none;
}

fn count(c: zokor.Ctx[App], r: http.Response) -> http.Response {
    c.state.requests = c.state.requests + 1;
    r.headers["x-request-count"] = to_str(c.state.requests);
    return r;
}

// Configuration is read once, here, and validated before anything runs.
let cfg = zokor.load_config();          // ".env", then the environment
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
r.post("/avatars", upload_avatar);
r.post("/webhooks/stripe", webhook);
r.before(require_token);
r.after(count);

// With a serve loop this would be:  r.listen_and_serve("0.0.0.0", 8080);

// ---------------------------------------------------------------- //
// the demo: stand-in requests, printed                               //
//                                                                    //
// Only because there is no accept loop yet. A real client sends these //
// bytes; nothing below is part of zokor's API.                       //
// ---------------------------------------------------------------- //

fn req(method: str, p: str, token: str, body: str) -> http.Request {
    let h: map[str]str = {};
    if len(token) > 0 {
        h["authorization"] = "Bearer " + token;
    }
    if len(body) > 0 {
        h["content-type"] = "application/json";
    }
    return http.Request {
        method: method,
        path: p,
        version: "HTTP/1.1",
        headers: h,
        body: to_bytes(body)
    };
}

fn multipart_req(token: str) -> http.Request {
    let body = "--B\r\n" +
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
        "My avatar\r\n" +
        "--B\r\n" +
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"../../etc/passwd.png\"\r\n" +
        "Content-Type: image/png\r\n\r\n" +
        "PNGDATA\r\n" +
        "--B--\r\n";
    let h: map[str]str = {};
    h["authorization"] = "Bearer " + token;
    h["content-type"] = "multipart/form-data; boundary=B";
    return http.Request {
        method: "POST",
        path: "/avatars",
        version: "HTTP/1.1",
        headers: h,
        body: to_bytes(body)
    };
}

fn bad_upload_req(token: str) -> http.Request {
    let body = "--B\r\n" +
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"x.svg\"\r\n" +
        "Content-Type: image/svg+xml\r\n\r\n" +
        "<svg/>\r\n" +
        "--B--\r\n";
    let h: map[str]str = {};
    h["authorization"] = "Bearer " + token;
    h["content-type"] = "multipart/form-data; boundary=B";
    return http.Request {
        method: "POST",
        path: "/avatars",
        version: "HTTP/1.1",
        headers: h,
        body: to_bytes(body)
    };
}

fn show(label: str, resp: http.Response) {
    println(label + " -> " + to_str(resp.status) + " " + to_str(resp.body));
}

println("routes:");
for line in r.routes_list() {
    println("  " + line);
}
println("");

show("GET    /", r.serve(req("GET", "/", "", "")));
show("GET    /search?q=slang&page=2", r.serve(req("GET", "/search?q=slang&page=2", "", "")));
show("GET    /orgs/7", r.serve(req("GET", "/orgs/7", "s3cret", "")));
show("GET    /orgs/9", r.serve(req("GET", "/orgs/9", "s3cret", "")));
show("GET    /orgs/7 (no token)", r.serve(req("GET", "/orgs/7", "", "")));
show("POST   /orgs (empty body)", r.serve(req("POST", "/orgs", "s3cret", "")));
show("POST   /orgs (bad values)",
     r.serve(req("POST", "/orgs", "s3cret",
                 "{\"name\":\"\",\"plan\":\"gold\",\"seats\":0}")));
show("POST   /orgs (wrong type)",
     r.serve(req("POST", "/orgs", "s3cret",
                 "{\"name\":\"acme\",\"plan\":\"pro\",\"seats\":\"many\"}")));
show("POST   /orgs (missing field)",
     r.serve(req("POST", "/orgs", "s3cret", "{\"name\":\"acme\"}")));
show("POST   /orgs",
     r.serve(req("POST", "/orgs", "s3cret",
                 "{\"name\":\"acme\",\"plan\":\"pro\",\"seats\":12,\"website\":\"https://acme.test\"}")));
show("POST   /webhooks/stripe",
     r.serve(req("POST", "/webhooks/stripe", "s3cret",
                 "{\"type\":\"invoice.paid\",\"data\":{\"customer\":{\"address\":{\"city\":\"Lagos\"}},\"items\":[{\"sku\":\"A1\"},{\"sku\":\"B2\"}]}}")));
show("POST   /avatars", r.serve(multipart_req("s3cret")));
show("POST   /avatars (svg)", r.serve(bad_upload_req("s3cret")));
show("GET    /files/a/b.txt", r.serve(req("GET", "/files/a/b.txt", "", "")));
show("HEAD   /", r.serve(req("HEAD", "/", "", "")));
show("DELETE /orgs/7", r.serve(req("DELETE", "/orgs/7", "s3cret", "")));
show("BREW   /", r.serve(req("BREW", "/", "", "")));
show("GET    /nope", r.serve(req("GET", "/nope", "s3cret", "")));
println("");
println("requests served: " + to_str(app.requests));
