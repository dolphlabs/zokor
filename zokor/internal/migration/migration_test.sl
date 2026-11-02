import "builder";

fn test_split_keeps_semicolons_in_strings_and_comments() {
    let r = statements("select E'a\\';b'; /* ; */ select $$c;d$$; -- tail");
    guard let ss = r else let e = err_of(r) { panic(e); }
    assert(len(ss) == 2);
    let invalid = statements("-- comments only");
    guard let _s = invalid else { return; }
    panic("empty migration accepted");
}

fn test_many_dollar_quotes_and_partial_delimiters() {
    let sb = builder.new_str();
    let i = 0;
    while i < 10000 {
        sb.write("select $aaa$partial $aaX then $aa$ and ; $aaa$;");
        i = i + 1;
    }
    let r = statements(sb.finish());
    guard let ss = r else let e = err_of(r) { panic(e); }
    assert(len(ss) == 10000);
}
