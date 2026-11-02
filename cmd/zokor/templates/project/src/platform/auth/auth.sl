import "http";
import "zokor";
import "../app" as app;

// Who is calling: the tenant named by the request's X-Api-Key (API_KEYS).
// A feature's routes run this before anything else, and read the tenant
// with c.local("tenant_id"); nothing else decides who a caller is.
pub fn require_tenant(c: zokor.Ctx[app.App]) -> opt[http.Response] {
    guard let tenant_id = zokor.api_key_client(c, c.state.settings.api_keys) else {
        return some(zokor.respond(c.errors, "unauthorized", c.request_id));
    }
    c.set_local("tenant_id", tenant_id);
    return none;
}
