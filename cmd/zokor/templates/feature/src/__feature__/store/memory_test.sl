import "../domain" as domain;

fn __entity__(tenant_id: str, id: str) -> domain.__Entity__ {
    return domain.__Entity__ { id: id, tenant_id: tenant_id, title: "t " + id, body: "" };
}

fn test_memory_keeps_tenants_apart() {
    let m = new_memory();
    let _a = memory_insert(m, __entity__("acme", "1"));
    let _b = memory_insert(m, __entity__("globex", "2"));
    let mine = memory_find(m, "acme", "1");
    guard let got = mine else { panic("find failed"); }
    guard let n = got else { panic("acme's __entity__ is missing"); }
    assert(n.id == "1");
    let theirs = memory_find(m, "acme", "2");
    guard let none_here = theirs else { panic("find failed"); }
    if let _n = none_here { panic("acme found globex's __entity__"); }
}

fn test_memory_refuses_a_duplicate_and_pages_in_order() {
    let m = new_memory();
    for id in ["1", "2", "3"] {
        let _r = memory_insert(m, __entity__("acme", id));
    }
    let again = memory_insert(m, __entity__("acme", "1"));
    if let _ok = again { panic("a duplicate id was inserted"); }
    let page = memory_list(m, "acme", 1, 1);
    guard let rows = page else { panic("list failed"); }
    assert(len(rows) == 1 && rows[0].id == "2", inspect(len(rows)));
}
