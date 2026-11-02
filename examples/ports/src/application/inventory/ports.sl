import "../../domain/inventory" as stock;

// C is explicit adapter state: function fields never capture credentials or globals.
pub gc struct StockPort[C] {
    context: C,
    lookup: fn(C, str, str) -> result[opt[stock.Stock], str],
}
