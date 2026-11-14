import Config

# Same environment variables as development (see config/dev.exs).
# MIX_TEST_PARTITION supports parallel CI runs.
config :ecb_platform, ECBPlatform.Repo,
  username: System.get_env("ECB_DB_USER", "postgres"),
  password: System.get_env("ECB_DB_PASSWORD"),
  hostname: System.get_env("ECB_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("ECB_DB_PORT", "5432")),
  database: "ecb_tenants_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :ecb_platform, :default_tenant,
  identifier: "default",
  name: "Default",
  db_name: "ecb_default_test#{System.get_env("MIX_TEST_PARTITION")}"

config :ecb_web, ECBWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "U7HJ6OSGtb6fh1hq4DMj1rfCFKiQMwvGKbwbiZhbFNBazvLDOB4vF5AJ8f4eK3zW",
  server: false

config :ecb_platform, ECBPlatform.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
