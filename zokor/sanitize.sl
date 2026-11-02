// Operator injection: the NoSQL half of input sanitisation.
//
// MongoDB reads an object key that starts with `$` as an operator and one
// with a `.` as a path. A login that passes the request body to a query --
// `{"user": "ada", "password": {"$ne": ""}}` -- matches any password. The
// guard, like express-mongo-sanitize, looks at every key of a JSON body
// (at any depth, inside arrays too) and every query-parameter name, and:
//
//   REJECT  answers 400 naming the key; the handler never runs (default)
//   STRIP   removes those keys and carries on with what is left
//
// Opt-in, because most services have no document store behind them:
//
//     r.mongo_sanitize(zokor.SanitizeMode.REJECT);    // or sanitize_from(cfg)
//
// The router applies it before any `before` hook, so nothing downstream
// sees an unchecked body. Values are not touched: `"$5 off"` is a fine
// string. A body that is not JSON (or not valid JSON) is left for the
// handler to refuse.
//
// SQL has no equivalent here on purpose. Pattern-blacklisting SQL rejects
// `O'Brien` and still misses real attacks; the defence is parameterised
// queries, which the Postgres helpers are built on.

import "encoding";
import "http";
import "strings";
import "internal/path";

pub enum SanitizeMode {
    OFF,
    REJECT,
    STRIP,
}

// MONGO_SANITIZE: off (default), reject or strip.
pub fn sanitize_from(cfg: Config) -> SanitizeMode {
    let v = strings.to_lower(str_or(cfg, "MONGO_SANITIZE", ""));
    if v == "" || v == "off" || v == "false" {
        return SanitizeMode.OFF;
    }
    if v == "reject" || v == "true" || v == "on" {
        return SanitizeMode.REJECT;
    }
    if v == "strip" {
        return SanitizeMode.STRIP;
    }
    record(cfg, "MONGO_SANITIZE", v, "must be off, reject or strip");
    return SanitizeMode.OFF;
}

// A key MongoDB would read as an operator or a path.
pub fn operator_key(k: str) -> bool {
    return strings.has_prefix(k, "$") || strings.contains(k, ".");
}

// The first operator key in `j`, as a path ("filter.$where",
// "items[2].$gt"), or "" when there is none.
pub fn find_operator_key(j: Json) -> str {
    return find_in(j, "");
}

fn find_in(j: Json, at: str) -> str {
    if j.is_object() {
        let i = 0;
        while i < len(j.keys) {
            let k = j.keys[i];
            let here = k;
            if len(at) > 0 {
                here = at + "." + k;
            }
            if operator_key(k) {
                return here;
            }
            let deeper = find_in(j.values[i], here);
            if len(deeper) > 0 {
                return deeper;
            }
            i = i + 1;
        }
        return "";
    }
    if j.is_array() {
        let i = 0;
        while i < len(j.items) {
            let deeper = find_in(j.items[i], at + "[" + to_str(i) + "]");
            if len(deeper) > 0 {
                return deeper;
            }
            i = i + 1;
        }
    }
    return "";
}

// Removes every operator key in `j`, at any depth, in place; returns how
// many were removed.
pub fn strip_operator_keys(j: Json) -> int {
    let removed = 0;
    if j.is_object() {
        let keys: [str] = [];
        let values: [Json] = [];
        let i = 0;
        while i < len(j.keys) {
            if operator_key(j.keys[i]) {
                removed = removed + 1;
            } else {
                removed = removed + strip_operator_keys(j.values[i]);
                push(keys, j.keys[i]);
                push(values, j.values[i]);
            }
            i = i + 1;
        }
        j.keys = keys;
        j.values = values;
    } else if j.is_array() {
        for it in j.items {
            removed = removed + strip_operator_keys(it);
        }
    }
    return removed;
}

// The decoded name of each `name=value` pair in a query string.
fn query_names(qs: str) -> [str] {
    let out: [str] = [];
    if len(qs) == 0 {
        return out;
    }
    for pair in strings.split(qs, "&") {
        let eq = strings.find(pair, "=");
        let raw = pair;
        if eq >= 0 {
            raw = strings.slice(pair, 0, eq);
        }
        push(out, encoding.form_decode(raw) ?? raw);
    }
    return out;
}

// `qs` without the pairs whose decoded name is an operator key.
fn strip_query(qs: str) -> str {
    let kept: [str] = [];
    for pair in strings.split(qs, "&") {
        let eq = strings.find(pair, "=");
        let raw = pair;
        if eq >= 0 {
            raw = strings.slice(pair, 0, eq);
        }
        if !operator_key(encoding.form_decode(raw) ?? raw) {
            push(kept, pair);
        }
    }
    return strings.join(kept, "&");
}

fn is_json_type(content_type: str) -> bool {
    let ct = media_type_of(content_type);
    return ct == "application/json" || ct == "text/json" || ends_with_json(ct);
}

// What the guard says about `req` under `mode`: "" to carry on (after
// stripping in place, in STRIP mode), or the offending key's path to
// refuse with.
pub fn sanitize_request(req: http.Request, mode: SanitizeMode) -> str {
    if mode == SanitizeMode.OFF {
        return "";
    }
    let qs = path.query_of(req.path);
    if len(qs) > 0 {
        for name in query_names(qs) {
            if operator_key(name) {
                if mode == SanitizeMode.REJECT {
                    return "query parameter '" + name + "'";
                }
                let base = strings.slice(req.path, 0, len(req.path) - len(qs) - 1);
                let rest = strip_query(qs);
                if len(rest) > 0 {
                    req.path = base + "?" + rest;
                } else {
                    req.path = base;
                }
                break;
            }
        }
    }
    if len(req.body) == 0 || !is_json_type(http.header(req, "content-type") ?? "") {
        return "";
    }
    let pr = parse(to_str(req.body));
    guard let j = pr else {
        return "";
    }
    let found = find_operator_key(j);
    if len(found) == 0 {
        return "";
    }
    if mode == SanitizeMode.REJECT {
        return "body key '" + found + "'";
    }
    strip_operator_keys(j);
    req.body = j.render_bytes();
    return "";
}
