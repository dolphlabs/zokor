// Startup wiring is the only package that knows the concrete adapter.
import "application/inventory" as inventory;
import "domain/inventory" as stock;
import "infrastructure/memory" as memory;
import "interfaces/web" as rest;
import "../../../zokor" as zokor;
import "http";

gc struct App { inventory: inventory.Service[memory.Store], tokens: zokor.TokenStore }
fn require_tenant(c: zokor.Ctx[App]) -> opt[http.Response] {
    guard let tenant_id = zokor.bearer_subject(c, c.state.tokens) else {
        return some(zokor.respond(c.errors, "unauthorized", c.request_id));
    }
    c.set_local("tenant_id", tenant_id);
    return none;
}
fn show_stock(c: zokor.Ctx[App]) -> http.Response {
    return rest.show(c.state.inventory, c.local("tenant_id"), c.param("sku"), c.errors, c.request_id);
}

fn main() {
    let cfg = zokor.load_config();
    let count = zokor.int_or(cfg, "EXAMPLE_STOCK", 7);
    let checked = zokor.check(cfg);
    guard let _config = checked else let e = err_of(checked) { println(e); exit(1); }
    let made = stock.new_stock("tenant_a", "pen", count);
    guard let row = made else let e = err_of(made) { println(e); exit(1); }
    let seeded = memory.new_store([row]);
    guard let adapter = seeded else let e = err_of(seeded) { println(e); exit(1); }
    let service = inventory.new_service(memory.new_stock_port(adapter));
    let tokens = zokor.new_token_store(0);
    let issued = tokens.issue("tenant_a");
    guard let token = issued else { println("token issue failed"); exit(1); }
    let router = zokor.new_router(App { inventory: service, tokens: tokens });
    rest.register_errors(router.errors);
    router.before(require_tenant);
    router.get("/stock/:sku", show_stock);
    // Drive the same handler pipeline hermetically. A server passes router to listen_and_serve.
    let denied = router.serve(zokor.get_request("/stock/pen").build());
    println("unauthenticated -> " + to_str(denied.status));
    let found = router.serve(zokor.get_request("/stock/pen").bearer(token).build());
    println("stock -> " + to_str(found.status) + " " + zokor.resp_text(found));
    let missing = router.serve(zokor.get_request("/stock/missing").bearer(token).build());
    println("missing -> " + to_str(missing.status) + " " + zokor.resp_error_code(missing));
}
main();
