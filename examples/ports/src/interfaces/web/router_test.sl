import "../../domain/inventory" as stock;
import "strings";

gc struct FakeAdapter { calls: int, failure: str }
fn lookup(ctx: FakeAdapter, tenant_id: str, sku: str) -> result[opt[stock.Stock], str] {
    ctx.calls += 1;
    if len(ctx.failure) > 0 { return err(ctx.failure); }
    if sku == "missing" { let absent: opt[stock.Stock] = none; return ok(absent); }
    let count = 7;
    if tenant_id == "tenant_b" { count = 2; }
    return ok(some(stock.Stock { tenant_id: tenant_id, sku: sku, available: count }));
}
fn service(ctx: FakeAdapter) -> inventory.Service[FakeAdapter] {
    return inventory.new_service(inventory.StockPort[FakeAdapter] { context: ctx, lookup: lookup });
}
fn token(store: zokor.TokenStore, tenant_id: str) -> str {
    let made = store.issue(tenant_id); guard let value = made else { panic("token issue failed"); } return value;
}
gc struct App { inventory: inventory.Service[FakeAdapter], tokens: zokor.TokenStore }
fn fake_auth(c: zokor.Ctx[App]) -> opt[http.Response] {
    guard let tenant_id = zokor.bearer_subject(c, c.state.tokens) else {
        return some(zokor.respond(c.errors, "unauthorized", c.request_id));
    }
    c.set_local("tenant_id", tenant_id); return none;
}
fn fake_show(c: zokor.Ctx[App]) -> http.Response {
    return show(c.state.inventory, c.local("tenant_id"), c.param("sku"), c.errors, c.request_id);
}
fn router(service: inventory.Service[FakeAdapter], tokens: zokor.TokenStore) -> zokor.Router[App] {
    let r = zokor.new_router(App { inventory: service, tokens: tokens });
    register_errors(r.errors); r.before(fake_auth); r.get("/stock/:sku", fake_show); return r;
}
fn test_private_stock_route_authenticates_before_the_port_and_keeps_tenants_separate() {
    let ctx = FakeAdapter { calls: 0, failure: "" };
    let tokens = zokor.new_token_store(0);
    let r = router(service(ctx), tokens);
    let denied = r.serve(zokor.get_request("/stock/pen").build());
    assert(denied.status == 401 && ctx.calls == 0);
    for tenant_id in ["tenant_a", "tenant_b"] {
        let response = r.serve(zokor.get_request("/stock/pen").bearer(token(tokens, tenant_id)).build());
        assert(response.status == 200 && zokor.resp_json(response).get("tenant_id").str_or("") == tenant_id);
        let expected = 7;
        if tenant_id == "tenant_b" { expected = 2; }
        assert(zokor.resp_json(response).get("available").int_or(0) == expected);
    }
    assert(ctx.calls == 2);
}
fn test_port_failure_and_absence_use_registered_envelopes_without_adapter_secrets() {
    let ctx = FakeAdapter { calls: 0, failure: "" };
    let tokens = zokor.new_token_store(0);
    let bearer = token(tokens, "tenant_a");
    let r = router(service(ctx), tokens);
    let missing = r.serve(zokor.get_request("/stock/missing").bearer(bearer).build());
    assert(missing.status == 404 && zokor.resp_error_code(missing) == "inventory.not_found");
    ctx.failure = "database password=secret";
    let failed = r.serve(zokor.get_request("/stock/pen").bearer(bearer).build());
    assert(failed.status == 503 && zokor.resp_error_code(failed) == "inventory.unavailable");
    assert(!strings.contains(zokor.resp_text(failed), "secret"));
}
fn test_invalid_sku_names_the_field_and_never_calls_the_port() {
    let ctx = FakeAdapter { calls: 0, failure: "" };
    let tokens = zokor.new_token_store(0);
    let r = router(service(ctx), tokens);
    let bad = r.serve(zokor.get_request("/stock/bad:sku").bearer(token(tokens, "tenant_a")).build());
    assert(bad.status == 422 && ctx.calls == 0);
    assert(strings.contains(zokor.resp_text(bad), "\"field\":\"sku\""));
}
