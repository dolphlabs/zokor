fn test_split() {
    let a = split("/orgs/7/keys");
    assert(len(a) == 3);
    assert(a[0] == "orgs");
    assert(a[1] == "7");
    assert(a[2] == "keys");
    assert(len(split("/")) == 0);
    assert(len(split("")) == 0);
    let b = split("/a//b/");
    assert(len(b) == 2);
    assert(b[1] == "b");
}

fn test_strip_query() {
    assert(strip_query("/a/b?x=1") == "/a/b");
    assert(strip_query("/a/b") == "/a/b");
    assert(strip_query("?x=1") == "");
}

fn test_query_get() {
    let qs = query_of("/s?q=slang&page=2&flag");
    assert(qs == "q=slang&page=2&flag");
    assert(query_get(qs, "q") == "slang");
    assert(query_get(qs, "page") == "2");
    assert(query_get(qs, "flag") == "");
    assert(query_get(qs, "missing") == "");
    assert(query_of("/s") == "");
}

fn test_query_all() {
    let all = query_all("q=slang&page=2&flag&name=ada%20l");
    assert(len(all) == 4);
    assert(all["q"] == "slang");
    assert(all["page"] == "2");
    assert(all["flag"] == "");
    assert(all["name"] == "ada l");
    assert(len(query_all("")) == 0);
    // a repeated key keeps its last value
    let rep = query_all("x=1&x=2");
    assert(len(rep) == 1);
    assert(rep["x"] == "2");
}

fn test_percent_decode() {
    assert(percent_decode("a+b") == "a b");
    assert(percent_decode("a%20b") == "a b");
    assert(percent_decode("plain") == "plain");
    assert(percent_decode("%zz") == "%zz");
    assert(query_get("name=ada%20l", "name") == "ada l");
}

fn test_param_and_wildcard() {
    assert(param_name(":id") == "id");
    assert(param_name("orgs") == "");
    assert(param_name(":") == "");
    assert(wildcard_name("*rest") == "rest");
    assert(wildcard_name("rest") == "");
}
