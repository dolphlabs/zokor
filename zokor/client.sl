// The client's address: who is actually on the other end of a request.
//
// The socket's peer is the client unless the peer is a proxy you trust,
// in which case the proxy's forwarding header says who it was relaying
// for. A header is believed only from a proxy listed in TRUSTED_PROXIES:
// from anyone else, it is whatever the client chose to write, and an
// address a client can choose cannot key a rate limit or go in a log.
//
// One header is read, X-Forwarded-For by default or RFC 7239 Forwarded
// with PROXY_HEADER=forwarded -- never both. If either were believed, a
// client could add the one your proxy does not set and it would arrive
// untouched.

import "strings";

pub gc struct TrustedProxies {
    // network, mask pairs, as unsigned 32-bit values in an int
    nets: [int],
    // the forwarding header read from a trusted peer, lowercase
    header: str,
}

pub fn no_trusted_proxies() -> TrustedProxies {
    let nets: [int] = [];
    return TrustedProxies { nets: nets, header: "x-forwarded-for" };
}

// "a.b.c.d" as an unsigned 32-bit value, or -1. Strict: four decimal
// octets of 0-255, no leading zeros (010 could be read as octal), no
// spaces, nothing else.
pub fn parse_ipv4(s: str) -> int {
    let b = to_bytes(s);
    let n = len(b);
    let v = 0;
    let octets = 0;
    let i = 0;
    while octets < 4 {
        if i >= n || b[i] < 48 || b[i] > 57 {
            return -1;
        }
        let start = i;
        let o = 0;
        while i < n && b[i] >= 48 && b[i] <= 57 {
            o = o * 10 + (b[i] - 48);
            i = i + 1;
            if i - start > 3 {
                return -1;
            }
        }
        if o > 255 || (i - start > 1 && b[start] == 48) {
            return -1;
        }
        v = v * 256 + o;
        octets = octets + 1;
        if octets < 4 {
            if i >= n || b[i] != 46 {
                return -1;
            }
            i = i + 1;
        }
    }
    if i != n {
        return -1;
    }
    return v;
}

fn mask_of(prefix: int) -> int {
    if prefix == 0 {
        return 0;
    }
    return (4294967295 << (32 - prefix)) & 4294967295;
}

// TRUSTED_PROXIES's value: comma-separated IPv4 addresses and CIDRs
// ("10.0.0.0/8, 192.168.1.10"). Every bad entry is reported, each with
// what to write instead.
pub fn parse_trusted_proxies(list: str) -> result[TrustedProxies, str] {
    let tp = no_trusted_proxies();
    let problems: [str] = [];
    for raw in strings.split(list, ",") {
        let e = strings.trim(raw);
        if len(e) == 0 {
            continue;
        }
        let slash = strings.find(e, "/");
        let addr_s = e;
        let prefix = 32;
        if slash >= 0 {
            addr_s = strings.slice(e, 0, slash);
            let p = to_int(strings.slice(e, slash + 1, len(e)));
            guard let pv = p else {
                push(problems, "'" + e + "': the prefix after / must be 0-32");
                continue;
            }
            if pv < 0 || pv > 32 {
                push(problems, "'" + e + "': the prefix after / must be 0-32");
                continue;
            }
            prefix = pv;
        }
        let addr = parse_ipv4(addr_s);
        if addr < 0 {
            push(problems, "'" + e + "' is not an IPv4 address or CIDR " +
                 "(write e.g. 10.0.0.1 or 10.0.0.0/8)");
            continue;
        }
        let m = mask_of(prefix);
        if (addr & m) != addr {
            push(problems, "'" + e + "' has host bits set: did you mean " +
                 ipv4_str(addr & m) + "/" + to_str(prefix) + "?");
            continue;
        }
        push(tp.nets, addr);
        push(tp.nets, m);
    }
    if len(problems) > 0 {
        return err(strings.join(problems, "; "));
    }
    return ok(tp);
}

pub fn ipv4_str(v: int) -> str {
    return to_str((v >> 24) & 255) + "." + to_str((v >> 16) & 255) + "." +
           to_str((v >> 8) & 255) + "." + to_str(v & 255);
}

impl TrustedProxies {
    pub fn trusts(self: TrustedProxies, ip: int) -> bool {
        if ip < 0 {
            return false;
        }
        let i = 0;
        while i < len(self.nets) {
            if (ip & self.nets[i + 1]) == self.nets[i] {
                return true;
            }
            i = i + 2;
        }
        return false;
    }

    pub fn is_empty(self: TrustedProxies) -> bool {
        return len(self.nets) == 0;
    }
}

// The address part of `inspect(link.peer())`, "a.b.c.d:port" -> "a.b.c.d".
// slang exposes no other way to read a peer's address; tests pin the
// format so a change there fails here rather than in production.
pub fn peer_ip_of(rendered: str) -> str {
    let colon = strings.find(rendered, ":");
    if colon < 0 {
        return rendered;
    }
    return strings.slice(rendered, 0, colon);
}

// Every value of header `name` (lowercase) in a raw header block, in
// order, split on commas and trimmed: repeated lines join as one list,
// as RFC 9110 5.3 reads them.
fn header_list(headers: bytes, name: str) -> [str] {
    let out: [str] = [];
    let n = len(headers);
    let nl = len(name);
    let i = 0;
    while i < n {
        let j = i;
        while j < n && headers[j] != 13 {
            j = j + 1;
        }
        // name, then ':' -- compared case-insensitively in place
        if j - i > nl && headers[i + nl] == 58 &&
           strings.from_bytes_lower(headers, i, i + nl) == name {
            let value = strings.from_bytes(headers, i + nl + 1, j);
            for part in strings.split(value, ",") {
                push(out, strings.trim(part));
            }
        }
        i = j + 2;
    }
    return out;
}

// RFC 7239's for= value of one Forwarded element ("for=1.2.3.4;proto=https",
// "for=\"1.2.3.4:443\""), as its bare IPv4 text, or "" when it has none.
fn forwarded_for(element: str) -> str {
    for pair in strings.split(element, ";") {
        let p = strings.trim(pair);
        if len(p) > 4 && strings.to_lower(strings.slice(p, 0, 4)) == "for=" {
            let v = strings.slice(p, 4, len(p));
            if strings.has_prefix(v, "\"") && strings.has_suffix(v, "\"") &&
               len(v) >= 2 {
                v = strings.slice(v, 1, len(v) - 1);
            }
            let colon = strings.find(v, ":");
            if colon >= 0 {
                v = strings.slice(v, 0, colon);
            }
            return v;
        }
    }
    return "";
}

// Who the request came from. Not behind a trusted proxy: the peer. Behind
// one: walk the forwarding header from the right -- the hop the trusted
// proxy itself appended -- past every trusted address, and take the first
// that is not. A hop that is not a plain IPv4 address stops the walk:
// nothing left of it can be trusted, so the last trusted hop is the
// answer. Every hop trusted: the leftmost is the client.
pub fn client_ip_of(peer_ip: str, headers: bytes, tp: TrustedProxies) -> str {
    if tp.is_empty() || !tp.trusts(parse_ipv4(peer_ip)) {
        return peer_ip;
    }
    let hops = header_list(headers, tp.header);
    let last_trusted = peer_ip;
    let i = len(hops) - 1;
    while i >= 0 {
        let h = hops[i];
        if tp.header == "forwarded" {
            h = forwarded_for(h);
        }
        let ip = parse_ipv4(h);
        if ip < 0 {
            return last_trusted;
        }
        if !tp.trusts(ip) {
            return h;
        }
        last_trusted = h;
        i = i - 1;
    }
    return last_trusted;
}
