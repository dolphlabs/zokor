import "zokor";

// The settings used by the service, captured once before it starts serving.
pub gc struct Settings {
    port: int,
    server: zokor.ServerConfig,
}

pub fn settings_from(cfg: zokor.Config) -> Settings {
    return Settings {
        port: zokor.require_port(cfg, "PORT"),
        server: zokor.server_config_from(cfg)
    };
}
