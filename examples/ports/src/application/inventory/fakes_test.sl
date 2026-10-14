import "../../domain/inventory" as stock;

// Test files are excluded from the production build, including these fakes.
gc struct Fake {
    answer: opt[stock.Stock], failure: str, calls: int, tenant_id: str, sku: str,
}
fn fake(answer: opt[stock.Stock], failure: str) -> Fake {
    return Fake { answer: answer, failure: failure, calls: 0, tenant_id: "", sku: "" };
}
fn fake_lookup(ctx: Fake, tenant_id: str, sku: str) -> result[opt[stock.Stock], str] {
    ctx.calls += 1; ctx.tenant_id = tenant_id; ctx.sku = sku;
    if len(ctx.failure) > 0 { return err(ctx.failure); }
    return ok(ctx.answer);
}
fn fake_port(ctx: Fake) -> StockPort[Fake] { return StockPort[Fake] { context: ctx, lookup: fake_lookup }; }

fn test_service_passes_tenant_and_sku_and_preserves_absence_and_failure() {
    let record = stock.Stock { tenant_id: "tenant_a", sku: "pen", available: 7 };
    let ctx = fake(some(record), "");
    let service = new_service(fake_port(ctx));
    let found = find(service, "tenant_a", "pen");
    guard let maybe = found else { panic("fake success failed"); }
    guard let row = maybe else { panic("stock missing"); }
    assert(row.available == 7 && ctx.calls == 1 && ctx.tenant_id == "tenant_a" && ctx.sku == "pen");
    ctx.answer = none;
    let absent = find(service, "tenant_a", "pen");
    guard let no_row = absent else { panic("absence became failure"); }
    guard let _s = no_row else {
        ctx.failure = "adapter unavailable";
        let failed = find(service, "tenant_a", "pen");
        guard let _r = failed else let e = err_of(failed) { assert(e == "adapter unavailable"); return; }
        panic("adapter failure discarded");
    }
    panic("absent stock fabricated");
}
fn test_invalid_identity_never_calls_the_port_and_bad_adapter_binding_is_rejected() {
    let ctx = fake(none, "");
    let service = new_service(fake_port(ctx));
    let invalid = find(service, "", "bad:sku");
    guard let _v = invalid else let e = err_of(invalid) {
        assert(ctx.calls == 0 && strings.contains(e, "tenant_id") && strings.contains(e, "sku"));
        ctx.answer = some(stock.Stock { tenant_id: "tenant_b", sku: "pen", available: 3 });
        let wrong = find(service, "tenant_a", "pen");
        guard let _w = wrong else { return; } panic("adapter crossed a tenant boundary");
    }
    panic("invalid identity reached the port");
}
