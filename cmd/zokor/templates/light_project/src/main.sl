// Read configuration once, use it as router state, and serve until SIGTERM.
import "zokor";
import "platform/config" as config;

let cfg = zokor.load_config();
let settings = config.settings_from(cfg);
let checked = zokor.check(cfg);
guard let _ok = checked else let e = err_of(checked) {
    println(e);
    exit(2);
}
let r = zokor.new_router(settings);
r.health();
let served = zokor.listen_and_serve_with(r, settings.port, settings.server);
guard let _done = served else {
    exit(1);
}
