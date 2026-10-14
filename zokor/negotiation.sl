// Startup-compiled representations and bounded RFC 9110 Accept negotiation.
import "internal/accept" as acceptwire;
import "http";
import "strings";

pub gc struct AcceptLimits {
    max_bytes: int,
    max_ranges: int,
    max_params: int,
    max_offers: int,
    max_offer_bytes: int,
}

pub fn accept_limits() -> AcceptLimits {
    return AcceptLimits { max_bytes: 8192, max_ranges: 64, max_params: 32,
        max_offers: 32, max_offer_bytes: 1024 };
}

// Treat the compiled vectors as immutable after startup.
pub gc struct Negotiator {
    offers: [str],
    types: [str],
    subtypes: [str],
    params: [[str]],
    max_bytes: int,
    max_ranges: int,
    max_params: int,
}

// Offer order breaks otherwise equal preferences. Collect all startup failures.
pub fn new_negotiator(offers: [str], limits: AcceptLimits) -> result[Negotiator, str] {
    let problems: [str] = [];
    if limits.max_bytes < 1 { push(problems, "max_bytes must be positive"); }
    if limits.max_ranges < 1 { push(problems, "max_ranges must be positive"); }
    if limits.max_params < 0 { push(problems, "max_params must be nonnegative"); }
    if limits.max_offers < 1 { push(problems, "max_offers must be positive"); }
    if limits.max_offer_bytes < 1 { push(problems, "max_offer_bytes must be positive"); }
    if len(offers) == 0 || len(offers) > limits.max_offers { push(problems, "offers must contain 1..max_offers representations"); }
    let copied: [str] = [];
    let types: [str] = [];
    let subtypes: [str] = [];
    let params: [[str]] = [];
    let i = 0;
    for offer in offers {
        let name = "offers[" + to_str(i) + "]";
        i += 1;
        if len(offer) > limits.max_offer_bytes { push(problems, name + " exceeds max_offer_bytes"); continue; }
        let parsed = acceptwire.media(offer, limits.max_params);
        guard let m = parsed else let e = err_of(parsed) { push(problems, name + ": " + e); continue; }
        push(copied, offer); push(types, m.mtype); push(subtypes, m.subtype); push(params, m.params);
    }
    if len(problems) > 0 { return err("negotiation: " + strings.join(problems, "; ")); }
    return ok(Negotiator { offers: copied, types: types, subtypes: subtypes, params: params,
        max_bytes: limits.max_bytes, max_ranges: limits.max_ranges, max_params: limits.max_params });
}

impl Negotiator {
    // none means no acceptable offer; err means malformed Accept. Missing selects first.
    pub fn choose(self: Negotiator, header: opt[str]) -> result[opt[str], str] {
        if len(self.offers) != len(self.types) { return err("negotiator has inconsistent offers"); }
        let picked = acceptwire.choose(header, self.types, self.subtypes, self.params,
            self.max_bytes, self.max_ranges, self.max_params);
        guard let i = picked else let e = err_of(picked) { return err(e); }
        if i < 0 { let absent: opt[str] = none; return ok(absent); }
        return ok(some(self.offers[i]));
    }
}

// A selected media type, or a registered 400/406 response. Always adds Vary: Accept.
pub fn negotiate[S](c: Ctx[S], n: Negotiator) -> result[str, http.Response] {
    c.add_header("vary", "Accept");
    let read = acceptwire.header(c.req.raw_headers, n.max_bytes);
    guard let header = read else let e = err_of(read) {
        return err(respond_fields(c.errors, "bad_request", [field("Accept", e)], c.request_id));
    }
    let picked = n.choose(header);
    guard let chosen = picked else let e = err_of(picked) {
        return err(respond_fields(c.errors, "bad_request", [field("Accept", e)], c.request_id));
    }
    guard let representation = chosen else {
        return err(respond_fields(c.errors, "not_acceptable",
            [field("Accept", "no offered representation is acceptable")], c.request_id));
    }
    return ok(representation);
}
