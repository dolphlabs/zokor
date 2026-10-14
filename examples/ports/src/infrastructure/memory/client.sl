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
