import "pg";
import "zokor";
import "../config" as config;
// zokor:imports -- `zokor add feature` adds each feature's service and store

// The service's state: its settings and every feature's service, each
// wired to its store once, here. Handlers reach it as c.state.
pub gc struct App {
    // zokor:fields
    settings: config.Settings
}

pub fn build(s: config.Settings, db: pg.Pool) -> result[App, str] {
    return ok(App {
        // zokor:build
        settings: s
    });
}

// The same state with every store in memory: what the tests build.
pub fn for_tests(s: config.Settings) -> App {
    return App {
        // zokor:test_build
        settings: s
    };
}
