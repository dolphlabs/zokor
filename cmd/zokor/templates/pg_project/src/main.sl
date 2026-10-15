// Startup, and nothing else: read the configuration once, open the
// database, build the app state, mount every feature's routes, serve
// until SIGTERM.
import "zokor";
import "platform/app" as app;
import "platform/config" as config;
import "platform/db" as db;
// zokor:imports -- `zokor add feature` adds each feature's server

let cfg = zokor.load_config();
let settings = config.settings_from(cfg);
let checked = zokor.check(cfg);
guard let _ok = checked else let e = err_of(checked) {
    println(e);
    exit(2);
}
let opened = db.open(cfg);
guard let pool = opened else let e = err_of(opened) {
    println("cannot open the database: " + e);
    exit(1);
}
let built = app.build(settings, pool);
guard let state = built else let e = err_of(built) {
    println("cannot start: " + e);
    exit(1);
}
let r = zokor.new_router(state);
r.health();
// zokor:mount
let served = zokor.listen_and_serve_with(r, settings.port, settings.server);
guard let _done = served else {
    exit(1);
}
