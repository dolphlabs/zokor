# Ports and fakes

> Ports and fakes

# Ports and fakes

The example source files are shown below.

Run from the repository root: `make example-ports`.

## `examples/ports/src/application/inventory/ports.sl`

```slang
import "../../domain/inventory" as stock;

// C is explicit adapter state: function fields never capture credentials or globals.
pub gc struct StockPort[C] {
    context: C,
    lookup: fn(C, str, str) -> result[opt[stock.Stock], str],
}
```

## `examples/ports/src/application/inventory/service.sl`

```slang
import "../../domain/inventory" as stock;
import "strings";

pub gc struct Service[C] { port: StockPort[C] }

pub fn new_service[C](port: StockPort[C]) -> Service[C] { return Service[C] { port: port }; }

// Tenant identity is resolved at the edge and passed through every port call.
pub fn find[C](service: Service[C], tenant_id: str, sku: str) -> result[opt[stock.Stock], str] {
    let checked = stock.key(tenant_id, sku);
    guard let _key = checked else let e = err_of(checked) { return err(e); }
    let lookup = service.port.lookup;
    let loaded = lookup(service.port.context, tenant_id, sku);
    guard let maybe = loaded else let e = err_of(loaded) { return err(e); }
    if let row = maybe {
        if row.tenant_id != tenant_id || row.sku != sku { return err("adapter returned a different tenant_id or sku"); }
        if row.available < 0 { return err("adapter returned a negative available count"); }
    }
    return ok(maybe);
}

// Share the domain rule with the HTTP edge without importing adapters.
pub fn valid_sku(sku: str) -> bool { return stock.identifier(sku); }
```

## `examples/ports/src/domain/inventory/stock.sl`

```slang
import "strings";

pub struct Stock { tenant_id: str, sku: str, available: int }

pub fn identifier(value: str) -> bool {
    if len(value) < 1 || len(value) > 64 { return false; }
    for ch in to_bytes(value) {
        if !((ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) ||
             (ch >= 48 && ch <= 57) || ch == 45 || ch == 95) { return false; }
    }
    return true;
}

// The separator cannot occur in either identifier: tenant keys stay distinct.
pub fn key(tenant_id: str, sku: str) -> result[str, str] {
    let problems: [str] = [];
    if !identifier(tenant_id) { push(problems, "tenant_id must contain 1..64 ASCII letters, digits, - or _"); }
    if !identifier(sku) { push(problems, "sku must contain 1..64 ASCII letters, digits, - or _"); }
    if len(problems) > 0 { return err(strings.join(problems, "; ")); }
    return ok(tenant_id + ":" + sku);
}

pub fn new_stock(tenant_id: str, sku: str, available: int) -> result[Stock, str] {
    let problems: [str] = [];
    let checked = key(tenant_id, sku);
    if let _key = checked {} else let e = err_of(checked) { push(problems, e); }
    if available < 0 { push(problems, "available must be nonnegative"); }
    if len(problems) > 0 { return err(strings.join(problems, "; ")); }
    return ok(Stock { tenant_id: tenant_id, sku: sku, available: available });
}
```

## `examples/ports/src/infrastructure/memory/client.sl`

```slang
import "../../application/inventory" as inventory;
import "../../domain/inventory" as stock;
import "strings";

// Seed once at startup; immutable afterwards, so readers do not need a lock.
pub gc struct Store { stocks: map[str]stock.Stock }

pub fn new_store(rows: [stock.Stock]) -> result[Store, str] {
    let values: map[str]stock.Stock = {};
    let problems: [str] = [];
    let i = 0;
    for row in rows {
        let made = stock.new_stock(row.tenant_id, row.sku, row.available);
        guard let checked = made else let e = err_of(made) {
            push(problems, "rows[" + to_str(i) + "]: " + e); i += 1; continue;
        }
        let key = stock.key(checked.tenant_id, checked.sku) ?? "";
        if has(values, key) { push(problems, "rows[" + to_str(i) + "]: duplicate tenant_id and sku"); }
        else { values[key] = checked; }
        i += 1;
    }
    if len(problems) > 0 { return err(strings.join(problems, "; ")); }
    return ok(Store { stocks: values });
}

pub fn lookup(ctx: Store, tenant_id: str, sku: str) -> result[opt[stock.Stock], str] {
    let checked = stock.key(tenant_id, sku);
    guard let key = checked else let e = err_of(checked) { return err(e); }
    if !has(ctx.stocks, key) { let absent: opt[stock.Stock] = none; return ok(absent); }
    return ok(some(ctx.stocks[key]));
}

pub fn new_stock_port(ctx: Store) -> inventory.StockPort[Store] {
    return inventory.StockPort[Store] { context: ctx, lookup: lookup };
}
```

## `examples/ports/src/interfaces/web/router.sl`

```slang
import "../../../../../zokor" as zokor;
import "../../application/inventory" as inventory;
import "http";
import "json";

pub fn register_errors(errors: zokor.Registry) {
    zokor.register(errors, "inventory.not_found", 404, "stock not found");
    zokor.register(errors, "inventory.unavailable", 503, "inventory is unavailable");
}

// The route wrapper resolves authentication and passes explicit values here.
pub fn show[C](service: inventory.Service[C], tenant_id: str, sku: str,
               errors: zokor.Registry, request_id: str) -> http.Response {
    if !inventory.valid_sku(sku) {
        return zokor.respond_fields(errors, "validation_failed",
            [zokor.field("sku", "must contain 1..64 ASCII letters, digits, - or _")], request_id);
    }
    let loaded = inventory.find(service, tenant_id, sku);
    guard let maybe = loaded else { return zokor.respond(errors, "inventory.unavailable", request_id); }
    guard let row = maybe else { return zokor.respond(errors, "inventory.not_found", request_id); }
    return zokor.ok_json(json.encode(row));
}
```

## `examples/ports/src/main.sl`

```slang
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
```
