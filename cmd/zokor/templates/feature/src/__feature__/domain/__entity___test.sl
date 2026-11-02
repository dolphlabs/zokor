fn test_a_valid_note_has_no_problems() {
    assert(len(problems("groceries", "milk")) == 0);
    assert(len(problems("t", "")) == 0, "an empty body is allowed");
}

fn test_every_problem_is_reported_with_its_field() {
    let long_title = "";
    while len(long_title) <= max_title_bytes() {
        long_title = long_title + "x";
    }
    let long_body = "";
    while len(long_body) <= max_body_bytes() {
        long_body = long_body + "0123456789";
    }
    let p = problems(long_title, long_body);
    assert(len(p) == 2, "got " + to_str(len(p)));
    assert(p[0].field == "title" && p[1].field == "body");
    assert(problems("", "")[0].reason == "must not be empty");
}
