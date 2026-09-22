// JSON, for the shapes you know and the ones you do not.
//
// slang's own `json` package already does the part Go does badly: you
// decode into a struct, a missing field is an error rather than a
// silent zero, and the message names the field
// ("field 'addr': field 'city': expected a string, got a number").
// Keep using it for a shape you have declared:
//
//     let r: result[CreateOrg, str] = json.decode(c.body_str());
//
// What it cannot do is the rest of the job, so zokor adds it:
//
//   * a wire name that is not a slang field name. There are no struct
//     tags, so `{"userName": ...}` cannot reach a `user_name` field.
//     `snake_keys` rewrites the keys before decoding, and `camel_keys`
//     rewrites them back on the way out.
//   * a shape nobody declared -- a webhook, a passthrough, a field
//     whose contents are another service's business. `parse` gives a
//     value you can walk, and `path` reaches into it in one call.
//   * building a response without concatenating strings by hand, which
//     is where quoting bugs come from.
//   * turning any of the above into the same error envelope everything
//     else uses, with the offending FIELD named.

import "builder";
import "http";

pub enum JsonKind {
    Null,
    Bool,
    Number,
    String,
    Array,
    Object,
}

pub gc struct Json {
    kind: JsonKind,
    bool_val: bool,
    // Numbers keep the text they arrived as, so a 64-bit id survives
    // being read as JSON and written back out.
    raw: str,
    text: str,
    items: [Json],
    keys: [str],
    values: [Json],
}

// ---------------------------------------------------------------- //
// Building                                                           //
// ---------------------------------------------------------------- //

fn empty(k: JsonKind) -> Json {
    let items: [Json] = [];
    let keys: [str] = [];
    let values: [Json] = [];
    return Json {
        kind: k,
        bool_val: false,
        raw: "",
        text: "",
        items: items,
        keys: keys,
        values: values
    };
}

pub fn jnull() -> Json {
    return empty(JsonKind.Null);
}

pub fn jbool(v: bool) -> Json {
    let j = empty(JsonKind.Bool);
    j.bool_val = v;
    return j;
}

pub fn jint(v: int) -> Json {
    let j = empty(JsonKind.Number);
    j.raw = to_str(v);
    return j;
}

pub fn jfloat(v: float) -> Json {
    let j = empty(JsonKind.Number);
    j.raw = to_str(v);
    return j;
}

pub fn jstr(v: str) -> Json {
    let j = empty(JsonKind.String);
    j.text = v;
    return j;
}

pub fn jobj() -> Json {
    return empty(JsonKind.Object);
}

pub fn jarr() -> Json {
    return empty(JsonKind.Array);
}

// Reading and building are METHODS, so lookups chain and nothing
// collides with the rest of the package:
//
//     body.get("user").get("name").str_or("")
//     body.path("items.0.sku").str_or("")
//     jobj().set_str("id", id).set_int("count", n).render()
impl Json {
    // Sets a key, replacing it if present, and returns the object so
    // calls chain.
    pub fn set(self: Json, key: str, v: Json) -> Json {
        if self.kind != JsonKind.Object {
            return self;
        }
        let i = 0;
        while i < len(self.keys) {
            if self.keys[i] == key {
                self.values[i] = v;
                return self;
            }
            i = i + 1;
        }
        push(self.keys, key);
        push(self.values, v);
        return self;
    }

    pub fn set_str(self: Json, key: str, v: str) -> Json {
        return self.set(key, jstr(v));
    }

    pub fn set_int(self: Json, key: str, v: int) -> Json {
        return self.set(key, jint(v));
    }

    pub fn set_float(self: Json, key: str, v: float) -> Json {
        return self.set(key, jfloat(v));
    }

    pub fn set_bool(self: Json, key: str, v: bool) -> Json {
        return self.set(key, jbool(v));
    }

    // Only when the value is there: the difference between "absent"
    // and "null" belongs to the caller, not to the encoder.
    pub fn set_opt_str(self: Json, key: str, v: opt[str]) -> Json {
        guard let got = v else {
            return self;
        }
        return self.set(key, jstr(got));
    }

    pub fn add(self: Json, v: Json) -> Json {
        if self.kind != JsonKind.Array {
            return self;
        }
        push(self.items, v);
        return self;
    }

    pub fn add_str(self: Json, v: str) -> Json {
        return self.add(jstr(v));
    }

    pub fn add_int(self: Json, v: int) -> Json {
        return self.add(jint(v));
    }

    // A missing key, or an index that is not there, gives Null rather
    // than an error -- so a chain of lookups never has to be guarded at
    // every step. Ask `is_null`, or take a default with a `_or`.
    pub fn get(self: Json, key: str) -> Json {
        if self.kind != JsonKind.Object {
            return jnull();
        }
        let i = 0;
        while i < len(self.keys) {
            if self.keys[i] == key {
                return self.values[i];
            }
            i = i + 1;
        }
        return jnull();
    }

    pub fn at(self: Json, i: int) -> Json {
        if self.kind != JsonKind.Array || i < 0 || i >= len(self.items) {
            return jnull();
        }
        return self.items[i];
    }

    // "user.address.city", "items.0.name": one call instead of five.
    pub fn path(self: Json, p: str) -> Json {
        let cur = self;
        let b = to_bytes(p);
        let n = len(b);
        let start = 0;
        let i = 0;
        while i <= n {
            if i == n || b[i] == 46 {
                if i > start {
                    let seg = to_str(b[start..i]);
                    if cur.kind == JsonKind.Array {
                        cur = cur.at(to_int(seg) ?? -1);
                    } else {
                        cur = cur.get(seg);
                    }
                }
                start = i + 1;
            }
            i = i + 1;
        }
        return cur;
    }

    // Present, even if its value is null -- which is how a PATCH tells
    // "set this to nothing" from "leave it alone". (`has` is a slang
    // builtin for maps, so this one is spelled out.)
    pub fn has_key(self: Json, key: str) -> bool {
        if self.kind != JsonKind.Object {
            return false;
        }
        let i = 0;
        while i < len(self.keys) {
            if self.keys[i] == key {
                return true;
            }
            i = i + 1;
        }
        return false;
    }

    pub fn is_null(self: Json) -> bool {
        return self.kind == JsonKind.Null;
    }

    pub fn is_object(self: Json) -> bool {
        return self.kind == JsonKind.Object;
    }

    pub fn is_array(self: Json) -> bool {
        return self.kind == JsonKind.Array;
    }

    pub fn is_string(self: Json) -> bool {
        return self.kind == JsonKind.String;
    }

    pub fn is_number(self: Json) -> bool {
        return self.kind == JsonKind.Number;
    }

    pub fn is_bool(self: Json) -> bool {
        return self.kind == JsonKind.Bool;
    }

    // Items in an array, keys in an object, bytes in a string.
    pub fn size(self: Json) -> int {
        if self.kind == JsonKind.Array {
            return len(self.items);
        }
        if self.kind == JsonKind.Object {
            return len(self.keys);
        }
        if self.kind == JsonKind.String {
            return len(self.text);
        }
        return 0;
    }

    pub fn keys_of(self: Json) -> [str] {
        if self.kind != JsonKind.Object {
            let no_keys: [str] = [];
            return no_keys;
        }
        return self.keys;
    }

    pub fn items_of(self: Json) -> [Json] {
        if self.kind != JsonKind.Array {
            let no_items: [Json] = [];
            return no_items;
        }
        return self.items;
    }

    pub fn str_or(self: Json, fallback: str) -> str {
        if self.kind == JsonKind.String {
            return self.text;
        }
        return fallback;
    }

    pub fn int_or(self: Json, fallback: int) -> int {
        if self.kind == JsonKind.Number {
            return to_int(self.raw) ?? int_of_float(self.raw, fallback);
        }
        return fallback;
    }

    pub fn float_or(self: Json, fallback: float) -> float {
        if self.kind == JsonKind.Number {
            return to_float(self.raw) ?? fallback;
        }
        return fallback;
    }

    pub fn bool_or(self: Json, fallback: bool) -> bool {
        if self.kind == JsonKind.Bool {
            return self.bool_val;
        }
        return fallback;
    }

    // The JSON text of this value. Keys keep the order they were set
    // in, which makes a response diffable and a test readable.
    //
    // One builder for the whole document, so the cost is linear in its
    // size. (Each level used to return its own string to be joined by
    // its parent, which copies every byte once per level of nesting and
    // once per sibling: 128 KB of integers took ten seconds.)
    pub fn render(self: Json) -> str {
        let sb = builder.new_str();
        write_json(self, sb);
        return sb.finish();
    }
}

fn int_of_float(raw: str, fallback: int) -> int {
    guard let f = to_float(raw) else {
        return fallback;
    }
    return f as int;
}

fn write_json(j: Json, sb: builder.Str) -> int {
    if j.kind == JsonKind.Null {
        sb.write("null");
    } else if j.kind == JsonKind.Bool {
        if j.bool_val {
            sb.write("true");
        } else {
            sb.write("false");
        }
    } else if j.kind == JsonKind.Number {
        if len(j.raw) == 0 {
            sb.write("0");
        } else {
            sb.write(j.raw);
        }
    } else if j.kind == JsonKind.String {
        quote_into(sb, j.text);
    } else if j.kind == JsonKind.Array {
        sb.write("[");
        let i = 0;
        while i < len(j.items) {
            if i > 0 {
                sb.write(",");
            }
            write_json(j.items[i], sb);
            i = i + 1;
        }
        sb.write("]");
    } else {
        sb.write("{");
        let i = 0;
        while i < len(j.keys) {
            if i > 0 {
                sb.write(",");
            }
            quote_into(sb, j.keys[i]);
            sb.write(":");
            write_json(j.values[i], sb);
            i = i + 1;
        }
        sb.write("}");
    }
    return 0;
}

// ---------------------------------------------------------------- //
// Parsing                                                            //
// ---------------------------------------------------------------- //

gc struct Cursor {
    b: bytes,
    i: int,
    depth: int,
    fail: str,
}

// Nesting is bounded so a hostile body of 100,000 open brackets cannot
// take the stack down with it.
fn max_depth() -> int {
    return 64;
}

pub fn parse(text: str) -> result[Json, str] {
    let c = Cursor { b: to_bytes(text), i: 0, depth: 0, fail: "" };
    skip_ws(c);
    let v = parse_value(c);
    if len(c.fail) > 0 {
        return err(c.fail);
    }
    skip_ws(c);
    if c.i < len(c.b) {
        return err("unexpected text after the value at byte " + to_str(c.i));
    }
    return ok(v);
}

fn fail_at(c: Cursor, why: str) -> Json {
    if len(c.fail) == 0 {
        c.fail = why + " at byte " + to_str(c.i);
    }
    return jnull();
}

fn skip_ws(c: Cursor) {
    let n = len(c.b);
    while c.i < n {
        let ch = c.b[c.i];
        if ch == 32 || ch == 9 || ch == 10 || ch == 13 {
            c.i = c.i + 1;
        } else {
            return;
        }
    }
}

fn parse_value(c: Cursor) -> Json {
    if len(c.fail) > 0 {
        return jnull();
    }
    if c.i >= len(c.b) {
        return fail_at(c, "unexpected end of JSON");
    }
    if c.depth > max_depth() {
        return fail_at(c, "JSON nested deeper than " + to_str(max_depth()));
    }
    let ch = c.b[c.i];
    if ch == 123 {
        return parse_object(c);
    }
    if ch == 91 {
        return parse_array(c);
    }
    if ch == 34 {
        let s = parse_string(c);
        if len(c.fail) > 0 {
            return jnull();
        }
        return jstr(s);
    }
    if ch == 116 {
        return parse_literal(c, "true", jbool(true));
    }
    if ch == 102 {
        return parse_literal(c, "false", jbool(false));
    }
    if ch == 110 {
        return parse_literal(c, "null", jnull());
    }
    if ch == 45 || (ch >= 48 && ch <= 57) {
        return parse_number(c);
    }
    return fail_at(c, "unexpected character in JSON");
}

fn parse_literal(c: Cursor, word: str, v: Json) -> Json {
    let w = to_bytes(word);
    let n = len(w);
    if c.i + n > len(c.b) {
        return fail_at(c, "truncated '" + word + "'");
    }
    let i = 0;
    while i < n {
        if c.b[c.i + i] != w[i] {
            return fail_at(c, "expected '" + word + "'");
        }
        i = i + 1;
    }
    c.i = c.i + n;
    return v;
}

fn index_of_keys(o: Json) -> map[str]int {
    let m: map[str]int = {};
    let k = 0;
    while k < len(o.keys) {
        m[o.keys[k]] = k;
        k = k + 1;
    }
    return m;
}

fn parse_object(c: Cursor) -> Json {
    let o = jobj();
    // Built only for a large object: an empty map costs more than the
    // whole of a typical five-key object.
    let seen: opt[map[str]int] = none;
    c.i = c.i + 1;
    c.depth = c.depth + 1;
    skip_ws(c);
    if c.i < len(c.b) && c.b[c.i] == 125 {
        c.i = c.i + 1;
        c.depth = c.depth - 1;
        return o;
    }
    while true {
        skip_ws(c);
        if c.i >= len(c.b) || c.b[c.i] != 34 {
            return fail_at(c, "expected a key in double quotes");
        }
        let key = parse_string(c);
        if len(c.fail) > 0 {
            return jnull();
        }
        skip_ws(c);
        if c.i >= len(c.b) || c.b[c.i] != 58 {
            return fail_at(c, "expected ':' after a key");
        }
        c.i = c.i + 1;
        skip_ws(c);
        let v = parse_value(c);
        if len(c.fail) > 0 {
            return jnull();
        }
        // `set` searches the keys, which is linear per key and so
        // quadratic for a large object. Past a handful of keys a map of
        // key -> position answers "seen this one?" in constant time; a
        // duplicate replaces the earlier value and keeps its place, as
        // `set` does.
        if len(o.keys) < 12 {
            o.set(key, v);
        } else {
            let index = seen ?? index_of_keys(o);
            seen = some(index);
            if has(index, key) {
                o.values[index[key]] = v;
            } else {
                index[key] = len(o.keys);
                push(o.keys, key);
                push(o.values, v);
            }
        }
        skip_ws(c);
        if c.i >= len(c.b) {
            return fail_at(c, "unterminated object");
        }
        if c.b[c.i] == 44 {
            c.i = c.i + 1;
            continue;
        }
        if c.b[c.i] == 125 {
            c.i = c.i + 1;
            c.depth = c.depth - 1;
            return o;
        }
        return fail_at(c, "expected ',' or '}'");
    }
    return o;
}

fn parse_array(c: Cursor) -> Json {
    let a = jarr();
    c.i = c.i + 1;
    c.depth = c.depth + 1;
    skip_ws(c);
    if c.i < len(c.b) && c.b[c.i] == 93 {
        c.i = c.i + 1;
        c.depth = c.depth - 1;
        return a;
    }
    while true {
        skip_ws(c);
        let v = parse_value(c);
        if len(c.fail) > 0 {
            return jnull();
        }
        a.add(v);
        skip_ws(c);
        if c.i >= len(c.b) {
            return fail_at(c, "unterminated array");
        }
        if c.b[c.i] == 44 {
            c.i = c.i + 1;
            continue;
        }
        if c.b[c.i] == 93 {
            c.i = c.i + 1;
            c.depth = c.depth - 1;
            return a;
        }
        return fail_at(c, "expected ',' or ']'");
    }
    return a;
}

// A string is scanned for its end, and copied ONCE.
//
// With no escape in it -- nearly every string -- that is a single slice.
// With escapes, the clean stretches between them are written to a
// builder as slices and each escape as the bytes it stands for. (This
// used to append one byte at a time with `+`, which is quadratic: a
// 128 KB string took six seconds to parse.)
fn parse_string(c: Cursor) -> str {
    c.i = c.i + 1;
    let n = len(c.b);
    let start = c.i;
    let i = start;
    while i < n {
        let ch = c.b[i];
        if ch == 34 {
            c.i = i + 1;
            return to_str(c.b[start..i]);
        }
        if ch == 92 {
            break;
        }
        if ch < 32 {
            c.i = i;
            fail_at(c, "a control character must be escaped in a string");
            return "";
        }
        i = i + 1;
    }
    if i >= n {
        c.i = n;
        fail_at(c, "unterminated string");
        return "";
    }
    // there is at least one escape: assemble
    let out = builder.new_bytes();
    if i > start {
        out.write(c.b[start..i]);
    }
    c.i = i;
    while c.i < n {
        let ch = c.b[c.i];
        if ch == 34 {
            c.i = c.i + 1;
            return to_str(out.finish());
        }
        if ch == 92 {
            c.i = c.i + 1;
            if c.i >= n {
                fail_at(c, "unterminated escape");
                return "";
            }
            let e = c.b[c.i];
            if e == 110 {
                out.write_byte(10);
            } else if e == 116 {
                out.write_byte(9);
            } else if e == 114 {
                out.write_byte(13);
            } else if e == 98 {
                out.write_byte(8);
            } else if e == 102 {
                out.write_byte(12);
            } else if e == 34 || e == 92 || e == 47 {
                out.write_byte(e);
            } else if e == 117 {
                let cp = parse_hex4(c);
                if len(c.fail) > 0 {
                    return "";
                }
                out.write(utf8_of(cp));
                continue;
            } else {
                fail_at(c, "unknown escape");
                return "";
            }
            c.i = c.i + 1;
            continue;
        }
        if ch < 32 {
            fail_at(c, "a control character must be escaped in a string");
            return "";
        }
        // a clean stretch: find where it ends and copy it whole
        let from = c.i;
        while c.i < n {
            let cc = c.b[c.i];
            if cc == 34 || cc == 92 || cc < 32 {
                break;
            }
            c.i = c.i + 1;
        }
        out.write(c.b[from..c.i]);
    }
    fail_at(c, "unterminated string");
    return "";
}

// \uXXXX, including a surrogate pair.
fn parse_hex4(c: Cursor) -> int {
    c.i = c.i + 1;
    let hi = hex4(c);
    if len(c.fail) > 0 {
        return 0;
    }
    if hi >= 55296 && hi <= 56319 {
        if c.i + 1 < len(c.b) && c.b[c.i] == 92 && c.b[c.i + 1] == 117 {
            c.i = c.i + 2;
            let lo = hex4(c);
            if len(c.fail) > 0 {
                return 0;
            }
            if lo >= 56320 && lo <= 57343 {
                return 65536 + ((hi - 55296) * 1024) + (lo - 56320);
            }
            fail_at(c, "a high surrogate must be followed by a low one");
            return 0;
        }
        fail_at(c, "a lone high surrogate");
        return 0;
    }
    if hi >= 56320 && hi <= 57343 {
        fail_at(c, "a lone low surrogate");
        return 0;
    }
    return hi;
}

fn hex4(c: Cursor) -> int {
    if c.i + 4 > len(c.b) {
        fail_at(c, "truncated \\u escape");
        return 0;
    }
    let v = 0;
    let i = 0;
    while i < 4 {
        let d = hex_digit(c.b[c.i + i]);
        if d < 0 {
            fail_at(c, "bad hex digit in \\u escape");
            return 0;
        }
        v = v * 16 + d;
        i = i + 1;
    }
    c.i = c.i + 4;
    return v;
}

fn hex_digit(ch: int) -> int {
    if ch >= 48 && ch <= 57 { return ch - 48; }
    if ch >= 97 && ch <= 102 { return ch - 87; }
    if ch >= 65 && ch <= 70 { return ch - 55; }
    return -1;
}

fn utf8_of(cp: int) -> bytes {
    let one: bytes = b".";
    if cp < 128 {
        one[0] = cp;
        return one;
    }
    if cp < 2048 {
        let two: bytes = b"..";
        two[0] = 192 | (cp >> 6);
        two[1] = 128 | (cp & 63);
        return two;
    }
    if cp < 65536 {
        let three: bytes = b"...";
        three[0] = 224 | (cp >> 12);
        three[1] = 128 | ((cp >> 6) & 63);
        three[2] = 128 | (cp & 63);
        return three;
    }
    let four: bytes = b"....";
    four[0] = 240 | (cp >> 18);
    four[1] = 128 | ((cp >> 12) & 63);
    four[2] = 128 | ((cp >> 6) & 63);
    four[3] = 128 | (cp & 63);
    return four;
}

fn parse_number(c: Cursor) -> Json {
    let start = c.i;
    let n = len(c.b);
    if c.i < n && c.b[c.i] == 45 {
        c.i = c.i + 1;
    }
    let digits = 0;
    // JSON forbids a leading zero (RFC 8259): "01" is not one, and a
    // parser that takes it will re-render something its peer reads
    // differently.
    let first_zero = c.i < n && c.b[c.i] == 48;
    while c.i < n && c.b[c.i] >= 48 && c.b[c.i] <= 57 {
        c.i = c.i + 1;
        digits = digits + 1;
    }
    if digits == 0 {
        return fail_at(c, "a number needs a digit");
    }
    if first_zero && digits > 1 {
        return fail_at(c, "a number must not have a leading zero");
    }
    if c.i < n && c.b[c.i] == 46 {
        c.i = c.i + 1;
        let frac = 0;
        while c.i < n && c.b[c.i] >= 48 && c.b[c.i] <= 57 {
            c.i = c.i + 1;
            frac = frac + 1;
        }
        if frac == 0 {
            return fail_at(c, "a fraction needs a digit");
        }
    }
    if c.i < n && (c.b[c.i] == 101 || c.b[c.i] == 69) {
        c.i = c.i + 1;
        if c.i < n && (c.b[c.i] == 43 || c.b[c.i] == 45) {
            c.i = c.i + 1;
        }
        let exp = 0;
        while c.i < n && c.b[c.i] >= 48 && c.b[c.i] <= 57 {
            c.i = c.i + 1;
            exp = exp + 1;
        }
        if exp == 0 {
            return fail_at(c, "an exponent needs a digit");
        }
    }
    let j = empty(JsonKind.Number);
    j.raw = to_str(c.b[start..c.i]);
    return j;
}

// ---------------------------------------------------------------- //
// Key naming                                                         //
// ---------------------------------------------------------------- //

// slang has no struct tags, so a wire name is a field name. These
// rewrite the keys of a whole document so a camelCase API can decode
// into snake_case fields and back:
//
//     let body = zokor.snake_keys(c.body_str());
//     let r: result[CreateOrg, str] = json.decode(body);
//     ...
//     return zokor.ok_json(zokor.camel_keys(json.encode(org)));
pub fn snake_keys(text: str) -> str {
    let r = parse(text);
    guard let j = r else {
        return text;   // not JSON: leave it for the decoder to report
    }
    return rekey(j, true).render();
}

pub fn camel_keys(text: str) -> str {
    let r = parse(text);
    guard let j = r else {
        return text;
    }
    return rekey(j, false).render();
}

fn rekey(j: Json, to_snake: bool) -> Json {
    if j.kind == JsonKind.Array {
        let out = jarr();
        let i = 0;
        while i < len(j.items) {
            out.add(rekey(j.items[i], to_snake));
            i = i + 1;
        }
        return out;
    }
    if j.kind != JsonKind.Object {
        return j;
    }
    let out = jobj();
    let i = 0;
    while i < len(j.keys) {
        let k = j.keys[i];
        let nk = to_camel(k);
        if to_snake {
            nk = to_snake_case(k);
        }
        out.set(nk, rekey(j.values[i], to_snake));
        i = i + 1;
    }
    return out;
}

pub fn to_snake_case(s: str) -> str {
    let b = to_bytes(s);
    let out: bytes = b"";
    let one: bytes = b".";
    let i = 0;
    while i < len(b) {
        let ch = b[i];
        if ch >= 65 && ch <= 90 {
            if i > 0 {
                one[0] = 95;
                out = out + one;
            }
            one[0] = ch + 32;
            out = out + one;
        } else {
            one[0] = ch;
            out = out + one;
        }
        i = i + 1;
    }
    return to_str(out);
}

pub fn to_camel(s: str) -> str {
    let b = to_bytes(s);
    let out: bytes = b"";
    let one: bytes = b".";
    let up = false;
    let i = 0;
    while i < len(b) {
        let ch = b[i];
        if ch == 95 {
            up = true;
            i = i + 1;
            continue;
        }
        if up && ch >= 97 && ch <= 122 {
            one[0] = ch - 32;
        } else {
            one[0] = ch;
        }
        up = false;
        out = out + one;
        i = i + 1;
    }
    return to_str(out);
}

// ---------------------------------------------------------------- //
// Request bodies                                                     //
// ---------------------------------------------------------------- //

// The body as a value you can walk, with the failure already carrying
// a registered code. Use this for a shape you have not declared -- a
// webhook, a passthrough, a field that belongs to another service.
//
//     let r = zokor.json_body(c);
//     guard let body = r else let e = err_of(r) {
//         return zokor.respond_with(c.state.errors, e.code, e.detail,
//                                   c.request_id);
//     }
//     let city = body.path("address.city").str_or("");
pub fn parse_body(content_type: str, body: bytes) -> result[Json, FormError] {
    let ct = media_type_of(content_type);
    if len(ct) > 0 && ct != "application/json" && ct != "text/json" &&
       !ends_with_json(ct) {
        return err(FormError {
            code: "unsupported_media_type",
            detail: "expected application/json, got '" + ct + "'"
        });
    }
    if len(body) == 0 {
        return err(FormError {
            code: "bad_request",
            detail: "the request body is empty"
        });
    }
    let r = parse(to_str(body));
    guard let j = r else let e = err_of(r) {
        return err(FormError { code: "malformed_json", detail: e });
    }
    return ok(j);
}

// "application/vnd.api+json" and friends.
fn ends_with_json(ct: str) -> bool {
    let b = to_bytes(ct);
    let n = len(b);
    if n < 5 {
        return false;
    }
    return to_str(b[n - 5..n]) == "+json";
}

// The failure of slang's own `json.decode`, mapped into the envelope
// with the offending field named where the message carries one:
//
//     let r: result[CreateOrg, str] = json.decode(c.body_str());
//     guard let dto = r else let e = err_of(r) {
//         return zokor.decode_failed(c.state.errors, e, c.request_id);
//     }
pub fn decode_failed(reg: Registry, why: str,
                     request_id: str) -> http.Response {
    let field = field_in(why);
    if len(field) > 0 {
        let fields = [FieldError { field: field, reason: reason_in(why) }];
        return respond_fields(reg, "validation_failed", fields, request_id);
    }
    return respond_with(reg, "malformed_json", why, request_id);
}

// "field 'addr': field 'city': expected a string" -> "addr.city";
// "missing required field 'age'" -> "age".
fn field_in(why: str) -> str {
    let b = to_bytes(why);
    let n = len(b);
    let out = "";
    let i = 0;
    while i < n {
        if b[i] == 39 {
            let start = i + 1;
            let j = start;
            while j < n && b[j] != 39 {
                j = j + 1;
            }
            if j >= n {
                return out;
            }
            if len(out) > 0 {
                out = out + ".";
            }
            out = out + to_str(b[start..j]);
            i = j + 1;
            continue;
        }
        i = i + 1;
    }
    return out;
}

// The part after the last "field '...': ", which is the actual
// complaint ("expected a string, got a number").
fn reason_in(why: str) -> str {
    let b = to_bytes(why);
    let n = len(b);
    let last = -1;
    let i = 0;
    while i + 1 < n {
        if b[i] == 58 && b[i + 1] == 32 {
            last = i + 2;
        }
        i = i + 1;
    }
    if last < 0 {
        if starts_with_str(why, "missing required field") {
            return "is required";
        }
        return why;
    }
    return to_str(b[last..n]);
}

fn starts_with_str(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let i = 0;
    while i < len(b) {
        if a[i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// ---------------------------------------------------------------- //
// Validation                                                         //
// ---------------------------------------------------------------- //

// Decoding says a field is a string; it does not say the string is an
// email, or between 3 and 40 characters, or one of four words. That is
// the other half of every handler, and doing it by hand is how a
// service ends up with five different ways of saying "that is wrong".
//
//     let v = zokor.checker();
//     let name  = v.req_str(body, "name", 1, 80);
//     let email = v.req_email(body, "email");
//     let age   = v.opt_int(body, "age", 0, 150, 0);
//     if v.failed() {
//         return zokor.respond_fields(c.state.errors, "validation_failed",
//                                     v.fields, c.request_id);
//     }
//
// Every problem is collected, not just the first, because a client
// fixing one field at a time is a client making five requests.
pub gc struct Checker {
    fields: [FieldError],
}

pub fn checker() -> Checker {
    let none_yet: [FieldError] = [];
    return Checker { fields: none_yet };
}

impl Checker {
    pub fn failed(self: Checker) -> bool {
        return len(self.fields) > 0;
    }

    pub fn note(self: Checker, field: str, reason: str) -> int {
        push(self.fields, FieldError { field: field, reason: reason });
        return len(self.fields);
    }

    // A required string, with a length range. 0 for `max` means "no
    // maximum".
    pub fn req_str(self: Checker, j: Json, key: str, min: int,
                   max: int) -> str {
        let v = j.get(key);
        if v.is_null() {
            self.note(key, "is required");
            return "";
        }
        if !v.is_string() {
            self.note(key, "must be a string");
            return "";
        }
        let s = v.str_or("");
        if len(s) < min {
            if min == 1 {
                self.note(key, "must not be empty");
            } else {
                self.note(key, "must be at least " + to_str(min) +
                               " characters");
            }
            return s;
        }
        if max > 0 && len(s) > max {
            self.note(key, "must be at most " + to_str(max) + " characters");
        }
        return s;
    }

    pub fn opt_str(self: Checker, j: Json, key: str, max: int,
                   fallback: str) -> str {
        let v = j.get(key);
        if v.is_null() {
            return fallback;
        }
        if !v.is_string() {
            self.note(key, "must be a string");
            return fallback;
        }
        let s = v.str_or(fallback);
        if max > 0 && len(s) > max {
            self.note(key, "must be at most " + to_str(max) + " characters");
        }
        return s;
    }

    pub fn req_int(self: Checker, j: Json, key: str, min: int,
                   max: int) -> int {
        let v = j.get(key);
        if v.is_null() {
            self.note(key, "is required");
            return min;
        }
        if !v.is_number() {
            self.note(key, "must be a whole number");
            return min;
        }
        let n = v.int_or(min);
        if n < min || n > max {
            self.note(key, "must be between " + to_str(min) + " and " +
                           to_str(max));
        }
        return n;
    }

    pub fn opt_int(self: Checker, j: Json, key: str, min: int, max: int,
                   fallback: int) -> int {
        let v = j.get(key);
        if v.is_null() {
            return fallback;
        }
        if !v.is_number() {
            self.note(key, "must be a whole number");
            return fallback;
        }
        let n = v.int_or(fallback);
        if n < min || n > max {
            self.note(key, "must be between " + to_str(min) + " and " +
                           to_str(max));
        }
        return n;
    }

    pub fn req_bool(self: Checker, j: Json, key: str) -> bool {
        let v = j.get(key);
        if v.is_null() {
            self.note(key, "is required");
            return false;
        }
        if !v.is_bool() {
            self.note(key, "must be true or false");
            return false;
        }
        return v.bool_or(false);
    }

    pub fn req_email(self: Checker, j: Json, key: str) -> str {
        let s = self.req_str(j, key, 1, 254);
        if len(s) == 0 {
            return s;
        }
        let r = valid.is_email(s);
        guard let _ok = r else let e = err_of(r) {
            self.note(key, e);
            return s;
        }
        return s;
    }

    pub fn req_url(self: Checker, j: Json, key: str) -> str {
        let s = self.req_str(j, key, 1, 2048);
        if len(s) == 0 {
            return s;
        }
        let r = valid.is_url(s);
        guard let _ok = r else let e = err_of(r) {
            self.note(key, e);
            return s;
        }
        return s;
    }

    pub fn req_uuid(self: Checker, j: Json, key: str) -> str {
        let s = self.req_str(j, key, 1, 36);
        if len(s) == 0 {
            return s;
        }
        let r = valid.is_uuid(s);
        guard let _ok = r else let e = err_of(r) {
            self.note(key, e);
            return s;
        }
        return s;
    }

    pub fn req_one_of(self: Checker, j: Json, key: str,
                      allowed: [str]) -> str {
        let s = self.req_str(j, key, 1, 0);
        if len(s) == 0 {
            return s;
        }
        let r = valid.is_one_of(s, allowed);
        guard let _ok = r else let e = err_of(r) {
            self.note(key, e);
            return s;
        }
        return s;
    }

    // A list of strings, with a cap on how many: the shape of "tags",
    // "recipients", "ids".
    pub fn req_strs(self: Checker, j: Json, key: str, max_items: int) -> [str] {
        let out: [str] = [];
        let v = j.get(key);
        if v.is_null() {
            self.note(key, "is required");
            return out;
        }
        if !v.is_array() {
            self.note(key, "must be an array");
            return out;
        }
        let items = v.items_of();
        if max_items > 0 && len(items) > max_items {
            self.note(key, "must have at most " + to_str(max_items) +
                           " items");
            return out;
        }
        let i = 0;
        while i < len(items) {
            if !items[i].is_string() {
                self.note(key + "." + to_str(i), "must be a string");
            } else {
                push(out, items[i].str_or(""));
            }
            i = i + 1;
        }
        return out;
    }

    // A nested object, so a checker can walk into it and report
    // "address.city" rather than "address".
    pub fn req_obj(self: Checker, j: Json, key: str) -> Json {
        let v = j.get(key);
        if v.is_null() {
            self.note(key, "is required");
            return jobj();
        }
        if !v.is_object() {
            self.note(key, "must be an object");
            return jobj();
        }
        return v;
    }

    // Everything found so far, re-reported under a prefix: for a
    // nested object checked by its own function.
    pub fn under(self: Checker, prefix: str, other: Checker) -> int {
        let i = 0;
        while i < len(other.fields) {
            push(self.fields, FieldError {
                field: prefix + "." + other.fields[i].field,
                reason: other.fields[i].reason
            });
            i = i + 1;
        }
        return len(self.fields);
    }
}
