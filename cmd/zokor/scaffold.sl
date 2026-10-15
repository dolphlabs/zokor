// `zokor new` and `zokor add feature`: a service laid out the way
// AGENTS.md (in the generated project) describes, from the templates in
// cmd/zokor/templates/ (embedded by gen_templates.sh as templates.sl).
//
// A generated project compiles and passes its tests as it stands; a
// feature added later is wired in at the `// zokor:` markers in
// src/platform/app/app.sl and src/main.sl, so neither command has to
// parse slang.

import "fs";
import "os";
import "strings";

gc struct Vars {
    service: str,
    feature: str,
    feature_cap: str,
    entity: str,
    entity_cap: str,
    seq: str,
    pin: str,
}

// The pin a new project gets: the zokor this CLI was built from, unless
// --zokor-git/--zokor-tag say otherwise (an unreleased branch, a fork).
fn default_git() -> str {
    return "https://github.com/dolphlabs/zokor";
}

fn default_tag() -> str {
    return "v0.2.0";
}

fn subst(s: str, v: Vars) -> str {
    let out = strings.replace(s, "__zokor_pin__", v.pin);
    out = strings.replace(out, "__service__", v.service);
    out = strings.replace(out, "__Feature__", v.feature_cap);
    out = strings.replace(out, "__feature__", v.feature);
    out = strings.replace(out, "__Entity__", v.entity_cap);
    out = strings.replace(out, "__entity__", v.entity);
    out = strings.replace(out, "__seq__", v.seq);
    return out;
}

fn capitalised(s: str) -> str {
    if len(s) == 0 {
        return s;
    }
    return strings.to_upper(strings.slice(s, 0, 1)) + strings.slice(s, 1, len(s));
}

// "orders" -> "order", "categories" -> "category", "news" stays: a guess,
// which --entity overrides.
fn singular(s: str) -> str {
    if strings.has_suffix(s, "ies") && len(s) > 3 {
        return strings.slice(s, 0, len(s) - 3) + "y";
    }
    if strings.has_suffix(s, "ses") || strings.has_suffix(s, "ss") || !strings.has_suffix(s, "s") {
        return s;
    }
    return strings.slice(s, 0, len(s) - 1);
}

// Names that become package aliases and identifiers in the generated code.
fn reserved_feature(name: str) -> bool {
    for r in ["app", "auth", "config", "db", "platform", "zokor", "http", "pg", "json",
              "time", "main", "src", "store", "service", "server", "domain", "migrations",
              "test", "fn", "let", "if", "else", "for", "while", "return", "struct", "enum",
              "import", "pub", "gc", "match", "join", "spawn", "select", "case", "default"] {
        if name == r {
            return true;
        }
    }
    return false;
}

// "" when `name` can be a feature (a package directory and an identifier),
// else why not, saying what would do.
fn feature_name_problem(name: str) -> str {
    let b = to_bytes(name);
    if len(b) == 0 || len(b) > 40 {
        return "a feature name is 1-40 characters";
    }
    if b[0] < 97 || b[0] > 122 {
        return "a feature name starts with a lowercase letter (e.g. orders)";
    }
    for c in b {
        let ok_char = (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
        if !ok_char {
            return "a feature name is lowercase letters, digits and _ (e.g. line_items)";
        }
    }
    if reserved_feature(name) {
        return "'" + name + "' is used by the generated code: pick another name";
    }
    return "";
}

fn service_name_problem(name: str) -> str {
    let b = to_bytes(name);
    if len(b) == 0 || len(b) > 60 {
        return "a service name is 1-60 characters";
    }
    for c in b {
        let ok_char = (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45;
        if !ok_char {
            return "a service name is lowercase letters, digits, - and _ (e.g. billing-api)";
        }
    }
    return "";
}

fn entity_name_problem(name: str) -> str {
    let b = to_bytes(name);
    if len(b) == 0 || len(b) > 40 || b[0] < 97 || b[0] > 122 {
        return "an entity name is a lowercase word (e.g. --entity order)";
    }
    for c in b {
        if !((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95) {
            return "an entity name is lowercase letters, digits and _";
        }
    }
    return "";
}

fn joined(lines: [str]) -> str {
    return strings.join(lines, "\n") + "\n";
}

fn parent_of(path: str) -> str {
    let at = strings.rfind(path, "/");
    if at <= 0 {
        return "";
    }
    return strings.slice(path, 0, at);
}

// mkdir -p.
fn make_dirs(dir: str) -> result[bool, str] {
    if len(dir) == 0 || os.is_dir(dir) {
        return ok(true);
    }
    let up = make_dirs(parent_of(dir));
    guard let _u = up else let e = err_of(up) {
        return err(e);
    }
    let r = fs.mkdir(dir);
    guard let _m = r else let e = err_of(r) {
        if os.is_dir(dir) {
            return ok(true);
        }
        return err("cannot create " + dir + ": " + e);
    }
    return ok(true);
}

fn write_text(path: str, text: str) -> result[bool, str] {
    let d = make_dirs(parent_of(path));
    guard let _d = d else let e = err_of(d) {
        return err(e);
    }
    let cr = fs.create(path);
    guard let fd = cr else let e = err_of(cr) {
        return err("cannot write " + path + ": " + e);
    }
    let wr = fs.write(fd as int, to_bytes(text));
    let _c = fs.close(fd as int);
    guard let _w = wr else let e = err_of(wr) {
        return err("cannot write " + path + ": " + e);
    }
    return ok(true);
}

fn read_text(path: str) -> result[str, str] {
    let sr = os.size(path);
    guard let n = sr else let e = err_of(sr) {
        return err("cannot read " + path + ": " + e);
    }
    let orr = fs.open(path);
    guard let fd = orr else let e = err_of(orr) {
        return err("cannot read " + path + ": " + e);
    }
    let rr = fs.read(fd as int, n);
    let _c = fs.close(fd as int);
    guard let b = rr else let e = err_of(rr) {
        return err("cannot read " + path + ": " + e);
    }
    return ok(to_str(b));
}

// Every file of a template group under `root`, never over an existing one:
// a half-written project is worse than a refusal, so all paths are checked
// before any is written.
fn under(root: str, rel: str) -> str {
    if root == "." {
        return rel;
    }
    return root + "/" + rel;
}

fn write_group(root: str, ts: [Template], v: Vars, overwrite: [str]) -> result[[str], str] {
    let written: [str] = [];
    for t in ts {
        let path = under(root, subst(t.path, v));
        let replacing = false;
        for o in overwrite {
            if subst(o, v) == t.path || o == t.path {
                replacing = true;
            }
        }
        if os.exists(path) && !replacing {
            return err(path + " already exists: nothing was written");
        }
    }
    for t in ts {
        let rel = subst(t.path, v);
        let w = write_text(under(root, rel), subst(joined(t.lines), v));
        guard let _ok = w else let e = err_of(w) {
            return err(e);
        }
        push(written, rel);
    }
    return ok(written);
}

fn paths_of(ts: [Template]) -> [str] {
    let out: [str] = [];
    for t in ts {
        push(out, t.path);
    }
    return out;
}

// The next migration number, three digits: one past the highest NNN_ file.
fn next_seq(root: str) -> str {
    let dr = os.read_dir(under(root, "migrations"));
    let top = 0;
    if let names = dr {
        for n in names {
            let us = strings.find(n, "_");
            if us > 0 {
                let pr = to_int(strings.slice(n, 0, us));
                if let k = pr {
                    if k > top {
                        top = k;
                    }
                }
            }
        }
    }
    let s = to_str(top + 1);
    while len(s) < 3 {
        s = "0" + s;
    }
    return s;
}

// Inserts `lines` before the line holding `marker`, at that line's
// indentation. err when the marker is gone: the file was edited by hand,
// and the command says which line to put back.
fn insert_before(text: str, marker: str, lines: [str], file: str) -> result[str, str] {
    let all = strings.split(text, "\n");
    let out: [str] = [];
    let seen = false;
    for l in all {
        if !seen && strings.contains(l, marker) {
            seen = true;
            let indent = strings.slice(l, 0, len(l) - len(strings.trim_start(l)));
            for n in lines {
                push(out, indent + n);
            }
        }
        push(out, l);
    }
    if !seen {
        return err(file + " has no '" + marker + "' line: put it back where features are wired in");
    }
    return ok(strings.join(out, "\n"));
}

fn wire(root: str, file: str, edits: [Edit]) -> result[bool, str] {
    let path = under(root, file);
    let rr = read_text(path);
    guard let text = rr else let e = err_of(rr) {
        return err(e);
    }
    let cur = text;
    for e in edits {
        let ir = insert_before(cur, e.marker, e.lines, file);
        guard let next = ir else let why = err_of(ir) {
            return err(why);
        }
        cur = next;
    }
    return write_text(path, cur);
}

gc struct Edit {
    marker: str,
    lines: [str],
}

fn uses_postgres(root: str) -> bool {
    return os.is_dir(under(root, "src/platform/db"));
}

// The feature's lines in app.sl and main.sl. The store constructor is the
// project's: in memory, or on the pool for a --db pg project.
fn feature_edits(v: Vars, pg: bool) -> [[Edit]] {
    let f = v.feature;
    let ctor = f + "_store.in_memory()";
    if pg {
        ctor = f + "_store.on_postgres(db)";
    }
    let app_edits = [
        Edit { marker: "// zokor:imports", lines: [
            "import \"../../" + f + "/service\" as " + f + ";",
            "import \"../../" + f + "/store\" as " + f + "_store;"] },
        Edit { marker: "// zokor:fields", lines: [
            f + ": " + f + "." + v.feature_cap + "[" + f + "_store.Store],"] },
        Edit { marker: "// zokor:build", lines: [
            f + ": " + f + ".new_" + f + "(" + ctor + ", zokor.new_session_id),"] },
        Edit { marker: "// zokor:test_build", lines: [
            f + ": " + f + ".new_" + f + "(" + f + "_store.in_memory(), zokor.new_session_id),"] }
    ];
    let main_edits = [
        Edit { marker: "// zokor:imports", lines: ["import \"" + f + "/server\" as " + f + ";"] },
        Edit { marker: "// zokor:mount", lines: [f + ".mount(r);"] }
    ];
    return [app_edits, main_edits];
}

fn add_feature_at(root: str, v: Vars) -> result[[str], str] {
    let pg = uses_postgres(root);
    let fr = write_group(root, feature_templates(), v, []);
    guard let written = fr else let e = err_of(fr) {
        return err(e);
    }
    if pg {
        let pr = write_group(root, pg_feature_templates(), v, paths_of(pg_feature_templates()));
        guard let more = pr else let e = err_of(pr) {
            return err(e);
        }
        for m in more {
            if !has_path(written, m) {
                push(written, m);
            }
        }
    }
    let edits = feature_edits(v, pg);
    let a = wire(root, "src/platform/app/app.sl", edits[0]);
    guard let _a = a else let e = err_of(a) {
        return err(e);
    }
    let m = wire(root, "src/main.sl", edits[1]);
    guard let _m = m else let e = err_of(m) {
        return err(e);
    }
    return ok(written);
}

fn has_path(xs: [str], p: str) -> bool {
    for x in xs {
        if x == p {
            return true;
        }
    }
    return false;
}

fn feature_vars(service: str, feature: str, entity: str, root: str) -> Vars {
    return Vars { service: service, feature: feature, feature_cap: capitalised(feature),
                  entity: entity, entity_cap: capitalised(entity), seq: next_seq(root),
                  pin: "" };
}

// The service's name, from its slang.project.
fn service_of(root: str) -> result[str, str] {
    let rr = read_text(under(root, "slang.project"));
    guard let text = rr else {
        return err("no slang.project here: run zokor add from the service's root directory");
    }
    for l in strings.split(text, "\n") {
        if strings.has_prefix(l, "name ") {
            return ok(strings.trim(strings.slice(l, 5, len(l))));
        }
    }
    return err("slang.project has no name line");
}

fn new_project(name: str, pg: bool, git: str, tag: str) -> result[[str], str] {
    let sp = service_name_problem(name);
    if len(sp) > 0 {
        return err(sp);
    }
    if os.exists(name) {
        return err(name + " already exists: pick another name, or remove it first");
    }
    let pin = "pkg zokor git " + git + " tag " + tag + " dir zokor";
    let v = Vars { service: name, feature: "notes", feature_cap: "Notes", entity: "note",
                   entity_cap: "Note", seq: "001", pin: pin };
    let pr = write_group(name, project_templates(), v, []);
    guard let written = pr else let e = err_of(pr) {
        return err(e);
    }
    if pg {
        let over = write_group(name, pg_project_templates(), v, paths_of(pg_project_templates()));
        guard let more = over else let e = err_of(over) {
            return err(e);
        }
        for m in more {
            if !has_path(written, m) {
                push(written, m);
            }
        }
    }
    let fr = add_feature_at(name, v);
    guard let feature_files = fr else let e = err_of(fr) {
        return err(e);
    }
    for f in feature_files {
        push(written, f);
    }
    return ok(written);
}
