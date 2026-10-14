fn test_memory_adapter_keys_by_tenant_and_owns_its_startup_records() {
    let rows = [stock.Stock { tenant_id: "tenant_a", sku: "pen", available: 7 },
                stock.Stock { tenant_id: "tenant_b", sku: "pen", available: 2 }];
    let made = new_store(rows);
    guard let ctx = made else { panic("seed failed"); }
    rows[0] = stock.Stock { tenant_id: "tenant_a", sku: "pen", available: 99 };
    let service = inventory.new_service(new_stock_port(ctx));
    let found = inventory.find(service, "tenant_a", "pen");
    guard let maybe = found else { panic("lookup failed"); }
    guard let row = maybe else { panic("missing"); }
    assert(row.available == 7);
    let other = inventory.find(service, "tenant_c", "pen");
    guard let absent = other else { panic("absence failed"); }
    guard let _r = absent else { return; } panic("another tenant's stock leaked");
}
fn test_memory_seed_collects_invalid_and_duplicate_records() {
    let made = new_store([stock.Stock { tenant_id: "", sku: "bad:sku", available: -1 },
        stock.Stock { tenant_id: "tenant_a", sku: "pen", available: 1 },
        stock.Stock { tenant_id: "tenant_a", sku: "pen", available: 2 }]);
    guard let _s = made else let e = err_of(made) {
        assert(strings.contains(e, "rows[0]") && strings.contains(e, "duplicate")); return;
    }
    panic("invalid seed accepted");
}
