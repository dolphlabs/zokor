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
