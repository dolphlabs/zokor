import "http";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../service" as __feature__;

// The __feature__ routes: HTTP in, a use case called with explicit values, HTTP
// out. Nothing here decides a rule (domain/) or touches storage (store/).

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let g = r.group("/__feature__");
    g.before(auth.require_tenant);
    g.post("", create___entity__);
    g.get("", list___feature__);
    g.get("/:id", show___entity__);
    // zokor:routes -- `zokor add route` registers new routes here
    return 0;
}

fn create___entity__(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[New__Entity__, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let made = __feature__.create(c.state.__feature__, c.local("tenant_id"), body.title, body.body);
    guard let n = made else let f = err_of(made) {
        return failure(c, f);
    }
    return zokor.created(__entity___json(n).render(), "/__feature__/" + n.id);
}

fn show___entity__(c: zokor.Ctx[app.App]) -> http.Response {
    let found = __feature__.get(c.state.__feature__, c.local("tenant_id"), c.param("id"));
    guard let n = found else let f = err_of(found) {
        return failure(c, f);
    }
    return zokor.ok_json(__entity___json(n).render());
}

fn list___feature__(c: zokor.Ctx[app.App]) -> http.Response {
    let offset = c.query_int("offset", 0);
    let limit = c.query_int("limit", 50);
    if limit < 1 || limit > 100 || offset < 0 {
        return zokor.respond_fields(c.errors, "validation_failed",
            [zokor.field("limit", "must be 1-100, with offset 0 or more")], c.request_id);
    }
    let rows = __feature__.list(c.state.__feature__, c.local("tenant_id"), offset, limit);
    guard let ns = rows else let f = err_of(rows) {
        return failure(c, f);
    }
    return zokor.ok_json(__feature___json(ns));
}
