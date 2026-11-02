fn test_create_keeps_the_tenant_it_was_given() {
    let f = fake_store();
    let made = create(fake___feature__(f), "acme", "groceries", "milk");
    guard let n = made else { panic("create failed"); }
    assert(n.tenant_id == "acme" && n.id == "n1");
    assert(f.calls[0] == "insert acme/n1", f.calls[0]);
}

fn test_invalid_input_never_reaches_the_store() {
    let f = fake_store();
    let made = create(fake___feature__(f), "acme", "", "");
    guard let _n = made else let e = err_of(made) {
        assert(e.why == Why.Invalid && e.problems[0].field == "title");
        assert(len(f.calls) == 0, "the store was called");
        return;
    }
    panic("an empty title was accepted");
}

fn test_another_tenants___entity___is_not_found() {
    let f = fake_store();
    let _m = create(fake___feature__(f), "acme", "plan", "");
    let other = get(fake___feature__(f), "globex", "n1");
    guard let _n = other else let e = err_of(other) {
        assert(e.why == Why.NotFound);
        return;
    }
    panic("globex read acme's __entity__");
}

fn test_a_failing_store_is_unavailable_with_its_detail_kept() {
    let f = fake_store();
    f.failure = "connection refused";
    let r = list(fake___feature__(f), "acme", 0, 10);
    guard let _rows = r else let e = err_of(r) {
        assert(e.why == Why.Unavailable && e.detail == "connection refused");
        return;
    }
    panic("a failing store succeeded");
}
