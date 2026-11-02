import "zokor";
import "../domain" as domain;

// What crosses the wire, in both directions. Requests decode into these
// with zokor.dto (camelCase keys become snake_case; a missing field is a
// 422 that names it); responses are rendered here, never by hand.

gc struct New__Entity__ {
    title: str,
    body: str,
}

fn __entity___json(n: domain.__Entity__) -> zokor.Json {
    return zokor.jobj().set_str("id", n.id).set_str("title", n.title).set_str("body", n.body);
}

fn __feature___json(ns: [domain.__Entity__]) -> str {
    let arr = zokor.jarr();
    for n in ns {
        arr.add(__entity___json(n));
    }
    return zokor.jobj().set("data", arr).render();
}
