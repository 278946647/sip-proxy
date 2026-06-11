from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="GFC_", env_file=".env", extra="ignore")

    # API
    api_title: str = "Global Forwarding Control Plane API"
    api_version: str = "0.1.0"

    # Storage
    database_url: str = "sqlite+aiosqlite:///./gfc.db"

    # Node bootstrap / auth
    bootstrap_tokens: str = "demo-bootstrap"
    node_token_ttl_seconds: int = 365 * 24 * 3600
    admin_default_password: str = "admin123"
    auth_secret: str = "dev-auth-secret-change-me"

    # OpenVPN PKI storage (CA + issued client certs)
    pki_dir: str = "./data/pki"

    # Background monitor
    monitor_interval_seconds: int = 60
    node_offline_threshold_seconds: int = 120
    alert_dedup_minutes: int = 30

    # SOCKS health probe (curl -x socks5://… probe_url)
    socks_probe_url: str = "https://api.ipify.org"
    socks_probe_timeout_seconds: int = 12

    # Public API URL embedded in client line codes
    public_url: str = "http://127.0.0.1:8080"

    # Client device offline threshold
    client_offline_threshold_seconds: int = 120

    # SSH reverse tunnel base port on bastion (device port = base + device_id)
    client_ssh_port_base: int = 6000


settings = Settings()

