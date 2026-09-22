// A zokor service.
//
// Read the "the service" section below: that is the whole API, and it
// ends at `listen_and_serve`. The section after that is a client, not a
// server: it makes the same requests a curl would, over a real socket,
// so this file demonstrates the service by running it rather than by
// describing it.
import "http";
import "httpc";
import "time";
import "../../src" as zokor;

// ---------------------------------------------------------------- //
// the service                                                        //
// ---------------------------------------------------------------- //

gc struct App {
    name: str,
    requests: int,
    token: str,
}

fn home(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "hello from " + c.state.name);
}

fn search(c: zokor.Ctx[App]) -> http.Response {
    return zokor.text(200, "q=" + c.query("q") +
                           " page=" + to_str(c.query_int("page", 1)));
}

fn show_org(c: zokor.Ctx[App]) -> http.Response {
    let _who = c.local("user_id");     // put there by require_token
    if c.param("id") != "7" {
        return zokor.respond_with(c.errors, "org.not_found",
                                  "no such organisation '" + c.param("id") + "'",
                                  c.request_id);
    }
    return zokor.ok_json("{\"org\":\"7\"}");
}

// A DTO: a declared shape. `zokor.dto` fills it (slang's own
// json.decode underneath), a missing field is an error rather than a
// silent zero, and the field it names is already in the envelope.
gc struct CreateOrg {
    name: str,
    plan: str,
    seats: i32,
    website: opt[str],
}

fn create_org(c: zokor.Ctx[App]) -> http.Response {
    // the wire is camelCase, the struct is snake_case: no tags needed,
    // and a decode failure is already the response to return
    let r: result[CreateOrg, http.Response] = zokor.dto(c);
    guard let dto = r else let resp = err_of(r) {
        return resp;
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
        return zokor.respond_fields(c.errors, "validation_failed",
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
        return zokor.respond_with(c.errors, e.code, e.detail,
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
        return zokor.respond_with(c.errors, e.code, e.detail,
                                  c.request_id);
    }
    guard let avatar = zokor.file(form, "avatar") else {
        return zokor.respond_with(c.errors, "validation_failed",
                                  "no file was posted under 'avatar'",
                                  c.request_id);
    }
    // avatar.filename is already safe to use as one path segment
    return zokor.ok_json("{\"stored\":\"" + avatar.filename +
                         "\",\"type\":\"" + avatar.content_type +
                         "\",\"bytes\":" + to_str(len(avatar.data)) +
                         ",\"title\":\"" + zokor.value(form, "title") + "\"}");
}

// Middleware. A `before` may end the request, or resolve something and
// hand it to the handler through the context; an `after` sees whatever
// response came back, including one a before produced.
//
// Note what is NOT here: a list of public paths. This hook is attached
// to a group, so it only ever runs for the routes inside it.
fn require_token(c: zokor.Ctx[App]) -> opt[http.Response] {
    if c.bearer() != c.state.token {
        return some(zokor.respond(c.errors, "unauthorized",
                                  c.request_id));
    }
    // resolved once, at the edge, instead of in every handler
    c.set_local("user_id", "u_1");
    return none;
}

fn count(c: zokor.Ctx[App], r: http.Response) -> http.Response {
    c.state.requests = c.state.requests + 1;
    r.headers["x-request-count"] = to_str(c.state.requests);
    return r;
}

// Configuration is read once, here, and validated before anything runs.
let cfg = zokor.load_config();          // ".env", then the environment

let app = App {
    name: zokor.str_or(cfg, "SERVICE_NAME", "hello"),
    requests: 0,
    token: zokor.str_or(cfg, "API_TOKEN", "s3cret")
};

// new_router's own registry, carried onto every Ctx from here on --
// register the app's own codes on top of the built-ins it already has.
let r = zokor.new_router(app);
zokor.register(r.errors, "org.not_found", 404, "no such organisation");

// public: no authentication
r.get("/", home);
r.get("/search", search);
r.get("/files/*rest", asset);

// everything under /api needs a token, and says so once
let api = r.group("/api");
api.before(require_token);
api.get("/orgs/:id", show_org);
api.post("/orgs", create_org);
api.post("/avatars", upload_avatar);
api.post("/webhooks/stripe", webhook);

// counted for every request, public or not
r.after(count);


// The whole server, from here on. `listen_and_serve` accepts and spawns
// one task per connection; it returns when the process is asked to stop.
// A real service calls it and nothing else -- the spawn here is only so
// this file can also play the client below.
spawn zokor.listen_and_serve(r, port());

// ---------------------------------------------------------------- //
// the demo: a real client, over a real socket                        //
//                                                                    //
// Nothing below is part of zokor's API -- it is here so `make check`  //
// exercises the server end to end rather than describing it.         //
// ---------------------------------------------------------------- //

// A function, not a top-level `let`: the client helpers below are
// functions, and a top-level binding is local to the main task.
fn port() -> int {
    return 18080;
}

fn base() -> str {
    return "http://127.0.0.1:" + to_str(port());
}

fn deadline() -> until {
    return until_of(time.mono() + 5000000000);
}

fn send(rq: httpc.Request) -> httpc.Response {
    let c = httpc.new_client();
    let r2 = httpc.client_send(c, rq, deadline());
    guard let resp = r2 else let e = err_of(r2) {
        println("request failed: " + e);
        exit(1);
    }
    return resp;
}

fn call(method: str, p: str, token: str, body: str, ctype: str) -> httpc.Response {
    let rq = httpc.new_request(method, base() + p);
    if len(token) > 0 {
        rq.headers["authorization"] = "Bearer " + token;
    }
    if len(body) > 0 {
        rq.headers["content-type"] = ctype;
        rq.body = to_bytes(body);
    }
    return send(rq);
}

fn get(p: str) -> httpc.Response {
    return call("GET", p, "", "", "");
}

fn json_call(method: str, p: str, token: str, body: str) -> httpc.Response {
    return call(method, p, token, body, "application/json");
}

fn show(label: str, resp: httpc.Response) {
    println(label + " -> " + to_str(resp.status) + " " + to_str(resp.body));
}

// wait for the listener to be up before the first request
fn wait_ready() {
    let i = 0;
    while i < 200 {
        let c = httpc.new_client();
        let r2 = httpc.client_get(c, base() + "/", deadline());
        guard let _ok = r2 else {
            time.sleep(10000000);
            i = i + 1;
            continue;
        }
        return;
    }
    println("server never came up");
    exit(1);
}

wait_ready();

println("routes:");
for line in r.routes_list() {
    println("  " + line);
}
println("");

show("GET    /", get("/"));
show("GET    /search?q=slang&page=2", get("/search?q=slang&page=2"));
show("GET    /api/orgs/7", call("GET", "/api/orgs/7", "s3cret", "", ""));
show("GET    /api/orgs/9", call("GET", "/api/orgs/9", "s3cret", "", ""));
show("GET    /api/orgs/7 (no token)", get("/api/orgs/7"));
show("POST   /api/orgs (empty body)", call("POST", "/api/orgs", "s3cret", "", ""));
show("POST   /api/orgs (bad values)",
     json_call("POST", "/api/orgs", "s3cret",
               "{\"name\":\"\",\"plan\":\"gold\",\"seats\":0}"));
show("POST   /api/orgs (wrong type)",
     json_call("POST", "/api/orgs", "s3cret",
               "{\"name\":\"acme\",\"plan\":\"pro\",\"seats\":\"many\"}"));
show("POST   /api/orgs (missing field)",
     json_call("POST", "/api/orgs", "s3cret", "{\"name\":\"acme\"}"));
show("POST   /api/orgs",
     json_call("POST", "/api/orgs", "s3cret",
               "{\"name\":\"acme\",\"plan\":\"pro\",\"seats\":12,\"website\":\"https://acme.test\"}"));
show("POST   /api/webhooks/stripe",
     json_call("POST", "/api/webhooks/stripe", "s3cret",
               "{\"type\":\"invoice.paid\",\"data\":{\"customer\":{\"address\":{\"city\":\"Lagos\"}},\"items\":[{\"sku\":\"A1\"},{\"sku\":\"B2\"}]}}"));

let avatar = "--B\r\n" +
    "Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
    "My avatar\r\n" +
    "--B\r\n" +
    "Content-Disposition: form-data; name=\"avatar\"; filename=\"../../etc/passwd.png\"\r\n" +
    "Content-Type: image/png\r\n\r\n" +
    "PNGDATA\r\n" +
    "--B--\r\n";
show("POST   /avatars",
     call("POST", "/api/avatars", "s3cret", avatar,
          "multipart/form-data; boundary=B"));

let bad_avatar = "--B\r\n" +
    "Content-Disposition: form-data; name=\"avatar\"; filename=\"x.svg\"\r\n" +
    "Content-Type: image/svg+xml\r\n\r\n" +
    "<svg/>\r\n" +
    "--B--\r\n";
show("POST   /avatars (svg)",
     call("POST", "/api/avatars", "s3cret", bad_avatar,
          "multipart/form-data; boundary=B"));

show("GET    /files/a/b.txt", get("/files/a/b.txt"));
show("HEAD   /", call("HEAD", "/", "", "", ""));
show("DELETE /api/orgs/7", call("DELETE", "/api/orgs/7", "s3cret", "", ""));
show("BREW   /", call("BREW", "/", "", "", ""));
show("GET    /nope", call("GET", "/nope", "s3cret", "", ""));
println("");
// one more than the calls above: wait_ready's probe is a request
// like any other, and the `count` hook counts every one.
println("requests served: " + to_str(app.requests));
