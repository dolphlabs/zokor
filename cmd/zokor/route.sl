// `zokor add route <feature> <METHOD> <path> <handler>`: registers a route
// in src/<feature>/server/server.sl at its `// zokor:routes` marker, adds
// a handler that answers 501 until it is written, and a test that the
// route is mounted behind the feature's authentication. The path is under
// the feature's prefix: `zokor add route orders POST /:id/cancel cancel`
// serves POST /orders/:id/cancel.

import "os";
import "strings";

fn route_method(m: str) -> str {
    let up = strings.to_upper(m);
    for k in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
        if up == k {
            return up;
        }
    }
    return "";
}

// "" when `p` is a path under the prefix: "" or "/..." with literal,
// `:param` and a final `*rest` segments.
fn route_path_problem(p: str) -> str {
    if len(p) == 0 {
        return "";
    }
    if !strings.has_prefix(p, "/") {
        return "a route path starts with / and is under the feature's prefix (e.g. /:id/cancel)";
    }
    let segs = strings.split(strings.slice(p, 1, len(p)), "/");
    let i = 0;
    while i < len(segs) {
        let s = segs[i];
        if len(s) == 0 {
            return "a route path has no empty segments (" + p + ")";
        }
        let b = to_bytes(s);
        let start = 0;
        if b[0] == 58 || b[0] == 42 {
            start = 1;
            if len(b) == 1 {
                return "a parameter needs a name (" + s + ")";
            }
            if b[0] == 42 && i != len(segs) - 1 {
                return "a *wildcard is the last segment (" + p + ")";
            }
        }
        let k = start;
        while k < len(b) {
            let c = b[k];
            let ok_char = (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45 ||
                          c == 46 || (start == 0 && c >= 65 && c <= 90);
            if !ok_char {
                return "a path segment is letters, digits, - _ and . (" + s + ")";
            }
            k = k + 1;
        }
        i = i + 1;
    }
    return "";
}

fn handler_name_problem(h: str) -> str {
    let b = to_bytes(h);
    if len(b) == 0 || len(b) > 60 || b[0] < 97 || b[0] > 122 {
        return "a handler name is a lowercase identifier (e.g. cancel_order)";
    }
    for c in b {
        if !((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95) {
            return "a handler name is lowercase letters, digits and _";
        }
    }
    if reserved_feature(h) || h == "mount" || h == "failure" || h == "register_errors" {
        return "'" + h + "' is taken: pick another handler name";
    }
    return "";
}

// The path a test can request: every parameter filled in.
fn concrete_path(prefix: str, p: str) -> str {
    if len(p) == 0 {
        return prefix;
    }
    let out = prefix;
    for s in strings.split(strings.slice(p, 1, len(p)), "/") {
        if strings.has_prefix(s, ":") || strings.has_prefix(s, "*") {
            out = out + "/x";
        } else {
            out = out + "/" + s;
        }
    }
    return out;
}

fn group_method(m: str) -> str {
    return strings.to_lower(m);
}

fn add_route_at(root: str, feature: str, method: str, path: str, handler: str) -> result[[str], str] {
    let server = under(root, "src/" + feature + "/server/server.sl");
    let tests = under(root, "src/" + feature + "/server/server_test.sl");
    if !os.is_file(server) {
        return err("no " + server + ": add the feature first (zokor add feature " + feature + ")");
    }
    let sr = read_text(server);
    guard let text = sr else let e = err_of(sr) {
        return err(e);
    }
    if strings.contains(text, "fn " + handler + "(") {
        return err(server + " already has a function " + handler + ": nothing was written");
    }
    let reg = "g." + group_method(method) + "(\"" + path + "\", " + handler + ");";
    if strings.contains(text, "g." + group_method(method) + "(\"" + path + "\",") {
        return err(server + " already registers " + method + " /" + feature + path +
                   ": nothing was written");
    }
    let ir = insert_before(text, "// zokor:routes", [reg], "src/" + feature + "/server/server.sl");
    guard let wired = ir else let e = err_of(ir) {
        return err(e);
    }
    let full = "/" + feature + path;
    let stub = [
        "",
        "// " + method + " " + full + ". Answers 501 until it is written: decode with",
        "// zokor.dto, call a use case in ../service with the tenant, answer.",
        "fn " + handler + "(c: zokor.Ctx[app.App]) -> http.Response {",
        "    return zokor.respond(c.errors, \"not_implemented\", c.request_id);",
        "}"
    ];
    let w = write_text(server, strings.trim_end(wired) + "\n" + strings.join(stub, "\n") + "\n");
    guard let _w = w else let e = err_of(w) {
        return err(e);
    }
    let written = ["src/" + feature + "/server/server.sl"];
    let tr = read_text(tests);
    if let ttext = tr {
        let target = concrete_path("/" + feature, path);
        let enum_method = "zokor.Method." + method;
        let test = [
            "",
            "fn test_" + handler + "_is_mounted_behind_auth() {",
            "    let r = router_under_test();",
            "    let denied = r.serve(zokor.request(" + enum_method + ", \"" + target + "\").build());",
            "    assert(zokor.resp_status(denied) == 401, zokor.resp_text(denied));",
            "    let resp = r.serve(zokor.request(" + enum_method + ", \"" + target + "\")",
            "                       .header(\"x-api-key\", key_a()).build());",
            "    let st = zokor.resp_status(resp);",
            "    assert(st != 404 && st != 405, zokor.resp_text(resp));",
            "}"
        ];
        let tw = write_text(tests, strings.trim_end(ttext) + "\n" + strings.join(test, "\n") + "\n");
        guard let _t = tw else let e = err_of(tw) {
            return err(e);
        }
        push(written, "src/" + feature + "/server/server_test.sl");
    }
    return ok(written);
}
