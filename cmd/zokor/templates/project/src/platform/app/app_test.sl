import "zokor";
import "../config" as config;

fn test_the_test_state_carries_the_settings() {
    let m: map[str]str = {};
    m["PORT"] = "9000";
    let a = for_tests(config.settings_from(zokor.config_from_values(m)));
    assert(a.settings.port == 9000);
}
