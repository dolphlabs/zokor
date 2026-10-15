import "zokor";

fn test_without_a_database_url_the_pool_says_so() {
    let m: map[str]str = {};
    let r = open(zokor.config_from_values(m));
    if let _p = r {
        panic("a pool opened with no DATABASE_URL");
    }
}
