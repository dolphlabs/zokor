fn test_split_keeps_semicolons_in_strings_and_comments() {
    let r = statements("select E'a\\';b'; /* ; */ select $$c;d$$; -- tail");
    guard let ss = r else let e = err_of(r) { panic(e); }
    assert(len(ss) == 2);
    let invalid = statements("-- comments only");
    guard let _s = invalid else { return; }
    panic("empty migration accepted");
}
