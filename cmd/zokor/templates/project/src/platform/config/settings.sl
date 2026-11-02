import "zokor";

// Everything the service reads from its environment, read once at
// startup (zokor.load_config: .env, .env.<profile>, then the process
// environment). Nothing else reads configuration: handlers get these
// values through the app state. Problems are recorded on `cfg`, and
// zokor.check(cfg) reports them all at once.
pub gc struct Settings {
    service_name: str,
    port: int,
    // API_KEYS: comma-separated `tenant:key` pairs; the tenant is the key's name.
    api_keys: zokor.ApiKeys,
    // Timeouts, limits, logging, TLS: see zokor's server_config_from.
    server: zokor.ServerConfig,
}

pub fn settings_from(cfg: zokor.Config) -> Settings {
    return Settings {
        service_name: zokor.str_or(cfg, "SERVICE_NAME", "__service__"),
        port: zokor.require_port(cfg, "PORT"),
        api_keys: zokor.api_keys_from(cfg),
        server: zokor.server_config_from(cfg)
    };
}
