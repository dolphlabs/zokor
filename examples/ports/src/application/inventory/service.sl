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
