fn test_stock_collects_invalid_fields_and_keys_include_tenant() {
    let bad = new_stock("", "bad:sku", -1);
    guard let _s = bad else let e = err_of(bad) {
        assert(strings.contains(e, "tenant_id") && strings.contains(e, "sku") && strings.contains(e, "available"));
        assert((key("tenant_a", "sku") ?? "") != (key("tenant_b", "sku") ?? ""));
        return;
    }
    panic("invalid stock accepted");
}
