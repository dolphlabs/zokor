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
