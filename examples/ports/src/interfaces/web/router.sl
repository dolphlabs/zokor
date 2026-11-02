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
