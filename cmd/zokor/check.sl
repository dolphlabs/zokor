// `zokor check`: the layout rules the generated AGENTS.md states, enforced,
// so they hold after the hundredth change as on the first. One line per
// problem, `file:line: rule: what is wrong (what to do)`, or with --json
// one JSON object per line for an agent or an editor. Exit 1 when there
// are problems.
//
// It reads the source as text -- imports, a few call names, SQL literals
// -- and never compiles it: it is a fast pre-commit check, not a second
// type checker. The rules:
//
//   layout     src/<feature>/ holds domain/ service/ store/ server/, and
//              nothing but packages; src/platform/ holds shared packages
//   imports    server -> service -> domain; store implements its own
//              feature's service ports; platform/app wires; a feature
//              reaches another only through that feature's service
//   pure       domain/ and service/ import no I/O package and no zokor
//   pg         only store/ and platform/db import pg
//   sql        no SQL built by concatenating a value: pass it as $N
//   config     only src/main.sl and platform/config read configuration
//   tenant     every public use case in service/ takes a tenant_id
//   auth       every server.sl puts its routes behind require_tenant
//              (or says `// zokor:public`)
//   tests      every package has a *_test.sl
//
// Test files (*_test.sl) may import what their tests need; every other
// rule applies to them too except `tenant` and `auth`.

import "os";
import "strings";

gc struct Problem {
    file: str,
    line: int,
    rule: str,
    message: str,
}

gc struct Report {
    problems: [Problem],
    packages: int,
}

fn add(r: Report, file: str, line: int, rule: str, message: str) {
    push(r.problems, Problem { file: file, line: line, rule: rule, message: message });
}

fn layers() -> [str] {
    return ["domain", "service", "store", "server"];
}

fn io_packages() -> [str] {
    return ["pg", "http", "httpc", "http2", "net", "fs", "os", "proc", "io", "sql", "redis",
            "zokor"];
}

fn contains_str(xs: [str], x: str) -> bool {
    for y in xs {
        if y == x {
            return true;
        }
    }
    return false;
}

// Every .sl file under `dir` (a path relative to the project root),
// sorted, and every directory that holds one.
gc struct Tree {
    files: [str],
    dirs: [str],
}

fn walk(dir: str, t: Tree) {
    let lr = os.read_dir(dir);
    guard let names = lr else {
        return;
    }
    let sorted = sort_strs(names);
    let has_sl = false;
    for n in sorted {
        if strings.has_prefix(n, ".") {
            continue;
        }
        let p = dir + "/" + n;
        if os.is_dir(p) {
            walk(p, t);
        } else if strings.has_suffix(n, ".sl") {
            push(t.files, p);
            has_sl = true;
        }
    }
    if has_sl {
        push(t.dirs, dir);
    }
}

// Whether `a` sorts after `b`, byte by byte.
fn after(a: str, b: str) -> bool {
    let x = to_bytes(a);
    let y = to_bytes(b);
    let i = 0;
    while i < len(x) && i < len(y) {
        if x[i] != y[i] {
            return x[i] > y[i];
        }
        i = i + 1;
    }
    return len(x) > len(y);
}

fn sort_strs(xs: [str]) -> [str] {
    let out: [str] = [];
    for x in xs {
        push(out, x);
    }
    let i = 1;
    while i < len(out) {
        let k = i;
        while k > 0 && after(out[k - 1], out[k]) {
            let tmp = out[k];
            out[k] = out[k - 1];
            out[k - 1] = tmp;
            k = k - 1;
        }
        i = i + 1;
    }
    return out;
}

// Where a file or package directory sits: "main", "platform", or a
// feature layer; `feature` is the feature (or platform package) name,
// `layer` the layer ("" for platform and main).
gc struct Place {
    kind: str,
    feature: str,
    layer: str,
}

fn place_of(path: str) -> Place {
    let parts = strings.split(path, "/");
    if path == "src/main.sl" || (len(parts) == 2 && parts[0] == "src") {
        return Place { kind: "main", feature: "", layer: "" };
    }
    if len(parts) >= 3 && parts[1] == "platform" {
        return Place { kind: "platform", feature: parts[2], layer: "" };
    }
    if len(parts) >= 3 {
        return Place { kind: "feature", feature: parts[1], layer: parts[2] };
    }
    return Place { kind: "other", feature: "", layer: "" };
}

fn dir_of(path: str) -> str {
    let at = strings.rfind(path, "/");
    if at < 0 {
        return ".";
    }
    return strings.slice(path, 0, at);
}

// "src/a/b/../c" -> "src/a/c".
fn normalise(path: str) -> str {
    let out: [str] = [];
    for p in strings.split(path, "/") {
        if p == "." || len(p) == 0 {
            continue;
        }
        if p == ".." {
            if len(out) > 0 {
                let keep: [str] = [];
                let i = 0;
                while i < len(out) - 1 {
                    push(keep, out[i]);
                    i = i + 1;
                }
                out = keep;
            }
            continue;
        }
        push(out, p);
    }
    return strings.join(out, "/");
}

// An import's target: a project directory ("src/...") when it names one,
// the way slang resolves imports (a local directory first), else the
// package name itself.
gc struct Target {
    local: bool,
    path: str,
}

fn resolve(file: str, name: str) -> Target {
    let candidate = normalise(dir_of(file) + "/" + name);
    if os.is_dir(candidate) {
        return Target { local: true, path: candidate };
    }
    return Target { local: false, path: name };
}

// `import "x";` / `import "x" as y;` at the start of a line: the name.
fn import_of(line: str) -> str {
    let t = strings.trim(line);
    if !strings.has_prefix(t, "import \"") {
        return "";
    }
    let rest = strings.slice(t, 8, len(t));
    let end = strings.find(rest, "\"");
    if end <= 0 {
        return "";
    }
    return strings.slice(rest, 0, end);
}

fn is_test(path: str) -> bool {
    return strings.has_suffix(path, "_test.sl");
}

// "" when a file at `from` may import the project directory `to`, else
// why not and what to do instead.
fn import_problem(from: Place, to: Place) -> str {
    if from.kind == "feature" {
        if to.kind == "feature" && to.feature == from.feature {
            if from.layer == "domain" && to.layer != "domain" {
                return "domain imports its own " + to.layer +
                       ": domain is the bottom layer; move the shared part into domain/";
            }
            if from.layer == "service" && (to.layer == "store" || to.layer == "server") {
                return "service imports " + to.layer + ": a service reaches storage through " +
                       "ports.sl, and platform/app wires the store in";
            }
            if from.layer == "store" && to.layer == "server" {
                return "store imports server: a store implements the service's ports and " +
                       "knows nothing of HTTP";
            }
            if from.layer == "server" && to.layer == "store" {
                return "server imports store: call the service; only platform/app wires stores";
            }
            return "";
        }
        if to.kind == "feature" {
            if to.layer == "service" && from.layer == "service" {
                return "";
            }
            if to.layer == "domain" && (from.layer == "service" || from.layer == "server") {
                return "";
            }
            return from.layer + " imports " + to.feature + "/" + to.layer +
                   ": a feature reaches another only through that feature's service/";
        }
        if to.kind == "platform" {
            if from.layer == "server" && (to.feature == "app" || to.feature == "auth") {
                return "";
            }
            return from.layer + " imports platform/" + to.feature + ": only server/ reaches " +
                   "platform/app and platform/auth; pass what a layer needs as arguments";
        }
        return from.layer + " imports src/main.sl's directory: nothing imports main";
    }
    if from.kind == "platform" {
        if to.kind == "platform" {
            return "";
        }
        if to.kind == "feature" && from.feature == "app" &&
           (to.layer == "service" || to.layer == "store") {
            return "";
        }
        return "platform/" + from.feature + " imports " + to.feature + "/" + to.layer +
               ": only platform/app wires features in, through their service/ and store/";
    }
    if from.kind == "main" {
        if to.kind == "platform" || (to.kind == "feature" && to.layer == "server") {
            return "";
        }
        return "src/main.sl imports " + to.feature + "/" + to.layer +
               ": startup mounts each feature's server/ and builds the state with platform/app";
    }
    return "";
}

fn check_imports(r: Report, file: str, lines: [str]) {
    let from = place_of(file);
    let test = is_test(file);
    let n = 0;
    for l in lines {
        n = n + 1;
        let name = import_of(l);
        if len(name) == 0 {
            continue;
        }
        let t = resolve(file, name);
        if t.local {
            if !test {
                let why = import_problem(from, place_of(t.path + "/x.sl"));
                if len(why) > 0 {
                    add(r, file, n, "imports", why);
                }
            }
            continue;
        }
        if name == "pg" && !(from.kind == "feature" && from.layer == "store") &&
           !(from.kind == "platform" && from.feature == "db") {
            add(r, file, n, "pg", "imports pg: only store/ and platform/db do; hold a db.Db " +
                "or call a store through its port");
            continue;
        }
        if !test && from.kind == "feature" && (from.layer == "domain" || from.layer == "service") &&
           contains_str(io_packages(), name) {
            add(r, file, n, "pure", from.layer + " imports " + name + ": " + from.layer +
                " does no I/O; do it in store/ or server/ and pass the result in");
        }
    }
}

// A string literal whose text starts like SQL.
fn sql_literal_at(line: str) -> bool {
    let low = strings.to_lower(line);
    for kw in ["\"select ", "\"insert into ", "\"delete from ", "\"with ", "\" where ",
               "\"where ", "\"order by", "\" order by", "\"values (", "\" from "] {
        if strings.contains(low, kw) {
            return true;
        }
    }
    return strings.contains(low, "\"update ") && strings.contains(low, " set ");
}

// The text of `line` with string literals blanked to "", so `+` inside
// one is not seen.
fn code_only(line: str) -> str {
    let b = to_bytes(line);
    let out = b"";
    let one = b".";
    let in_str = false;
    let i = 0;
    while i < len(b) {
        let c = b[i];
        if in_str {
            if c == 92 {
                i = i + 2;
                continue;
            }
            if c == 34 {
                in_str = false;
                one[0] = 34;
                out = out + one;
            }
            i = i + 1;
            continue;
        }
        if c == 47 && i + 1 < len(b) && b[i + 1] == 47 {
            break;
        }
        if c == 34 {
            in_str = true;
        }
        one[0] = c;
        out = out + one;
        i = i + 1;
    }
    return to_str(out);
}

// In a statement holding SQL, every `+` must join two literals: a value
// concatenated into SQL is the injection the parameterised helpers exist
// to prevent.
fn check_sql(r: Report, file: str, lines: [str]) {
    let i = 0;
    while i < len(lines) {
        if !sql_literal_at(lines[i]) {
            i = i + 1;
            continue;
        }
        // the statement: from here to the line ending with ';'
        let start = i;
        let stmt = "";
        while i < len(lines) {
            stmt = stmt + " " + code_only(lines[i]);
            if strings.has_suffix(strings.trim(lines[i]), ";") {
                break;
            }
            i = i + 1;
        }
        i = i + 1;
        let parts = strings.split(stmt, "+");
        let k = 0;
        let bad = false;
        while k + 1 < len(parts) && !bad {
            let left = strings.trim(parts[k]);
            let right = strings.trim(parts[k + 1]);
            if !strings.has_suffix(left, "\"") || !strings.has_prefix(right, "\"") {
                bad = true;
            }
            k = k + 1;
        }
        if bad {
            add(r, file, start + 1, "sql", "SQL built by concatenating a value: write $1, $2 " +
                "... in the literal and pass the values as pg.arg_*");
        }
    }
}

fn check_config(r: Report, file: str, lines: [str]) {
    let p = place_of(file);
    if is_test(file) || p.kind == "main" || (p.kind == "platform" && p.feature == "config") {
        return;
    }
    let n = 0;
    for l in lines {
        n = n + 1;
        let c = code_only(l);
        if strings.contains(c, "proc.getenv(") || strings.contains(c, "load_config") {
            add(r, file, n, "config", "reads configuration: read it once in " +
                "platform/config/settings.sl and reach it as c.state.settings");
        }
    }
}

fn check_tenant(r: Report, file: str, lines: [str]) {
    let p = place_of(file);
    if is_test(file) || p.kind != "feature" || p.layer != "service" ||
       strings.has_suffix(file, "/ports.sl") {
        return;
    }
    let n = 0;
    for l in lines {
        n = n + 1;
        let t = strings.trim(l);
        if !strings.has_prefix(t, "pub fn ") || strings.has_prefix(t, "pub fn new_") {
            continue;
        }
        // the signature, up to its opening brace
        let sig = t;
        let k = n;
        while !strings.contains(sig, "{") && k < len(lines) {
            sig = sig + " " + strings.trim(lines[k]);
            k = k + 1;
        }
        if !strings.contains(sig, "tenant_id: str") {
            add(r, file, n, "tenant", "a use case without tenant_id: take the tenant as an " +
                "explicit argument and pass it to every store call");
        }
    }
}

fn check_auth(r: Report, file: str, text: str) {
    let p = place_of(file);
    if p.kind != "feature" || p.layer != "server" || !strings.has_suffix(file, "/server.sl") {
        return;
    }
    if strings.contains(text, "// zokor:public") {
        return;
    }
    if !strings.contains(code_only_text(text), "require_tenant") {
        add(r, file, 1, "auth", "routes not behind auth.require_tenant: add " +
            "g.before(auth.require_tenant) in mount, or write // zokor:public if they are " +
            "meant to be open");
    }
}

fn code_only_text(text: str) -> str {
    let out: [str] = [];
    for l in strings.split(text, "\n") {
        push(out, code_only(l));
    }
    return strings.join(out, "\n");
}

fn check_layout(r: Report, t: Tree) {
    // feature directories: src/<x>/ other than platform
    let lr = os.read_dir("src");
    guard let names = lr else {
        add(r, "src", 0, "layout", "no src/ directory: run zokor check from the service's root");
        return;
    }
    for n in sort_strs(names) {
        let p = "src/" + n;
        if !os.is_dir(p) || n == "platform" || strings.has_prefix(n, ".") {
            continue;
        }
        for layer in layers() {
            if !os.is_dir(p + "/" + layer) {
                add(r, p, 0, "layout", "feature " + n + " has no " + layer + "/: every feature " +
                    "has domain/ service/ store/ server/ (zokor add feature writes them)");
            }
        }
        let inner = os.read_dir(p);
        if let entries = inner {
            for e in sort_strs(entries) {
                if strings.has_prefix(e, ".") {
                    continue;
                }
                if !os.is_dir(p + "/" + e) {
                    add(r, p + "/" + e, 0, "layout", "a file directly in a feature: it belongs " +
                        "in one of its layers");
                } else if !contains_str(layers(), e) {
                    add(r, p + "/" + e, 0, "layout", "'" + e + "' is not a layer: a feature " +
                        "holds domain/ service/ store/ server/; split a large layer into files, " +
                        "or make a new feature");
                }
            }
        }
    }
    for d in t.dirs {
        let lr2 = os.read_dir(d);
        let tested = false;
        if let fs2 = lr2 {
            for f in fs2 {
                if strings.has_suffix(f, "_test.sl") {
                    tested = true;
                }
            }
        }
        if !tested && d != "src" {
            add(r, d, 0, "tests", "a package with no tests: add a *_test.sl beside it");
        }
    }
}

fn check_project(root_ok: bool) -> Report {
    let none_yet: [Problem] = [];
    let r = Report { problems: none_yet, packages: 0 };
    if !root_ok {
        add(r, ".", 0, "layout", "no slang.project here: run zokor check from the service's root");
        return r;
    }
    let files: [str] = [];
    let dirs: [str] = [];
    let t = Tree { files: files, dirs: dirs };
    walk("src", t);
    r.packages = len(t.dirs);
    check_layout(r, t);
    for f in t.files {
        let rr = read_text(f);
        guard let text = rr else {
            add(r, f, 0, "layout", "cannot read the file");
            continue;
        }
        let lines = strings.split(text, "\n");
        check_imports(r, f, lines);
        check_sql(r, f, lines);
        check_config(r, f, lines);
        if !is_test(f) {
            check_tenant(r, f, lines);
            check_auth(r, f, text);
        }
    }
    return r;
}

fn json_str(s: str) -> str {
    let out = strings.replace(s, "\\", "\\\\");
    out = strings.replace(out, "\"", "\\\"");
    return "\"" + out + "\"";
}

fn print_report(r: Report, json_out: bool) {
    for p in r.problems {
        if json_out {
            println("{\"file\":" + json_str(p.file) + ",\"line\":" + to_str(p.line) +
                    ",\"rule\":" + json_str(p.rule) + ",\"message\":" + json_str(p.message) + "}");
        } else {
            let where = p.file;
            if p.line > 0 {
                where = where + ":" + to_str(p.line);
            }
            println(where + ": " + p.rule + ": " + p.message);
        }
    }
    if !json_out {
        if len(r.problems) == 0 {
            println("zokor check: ok (" + to_str(r.packages) + " packages)");
        } else {
            println("zokor check: " + to_str(len(r.problems)) + " problem(s) in " +
                    to_str(r.packages) + " packages");
        }
    }
}
