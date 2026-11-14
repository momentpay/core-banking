import Config

# Database credentials come from the environment. Nothing secret is committed.
#   ECB_DB_HOST      default "localhost"
#   ECB_DB_PORT      default 5432
#   ECB_DB_USER      default "postgres"
#   ECB_DB_PASSWORD  default none (works with trust or peer authentication)
db_opts = [
  username: System.get_env("ECB_DB_USER", "postgres"),
  password: System.get_env("ECB_DB_PASSWORD"),
  hostname: System.get_env("ECB_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("ECB_DB_PORT", "5432"))
]

# Registry database (tenant list). Tenant databases are created per tenant.
config :ecb_platform,
       ECBPlatform.Repo,
       db_opts ++
         [
           database: "ecb_tenants",
           stacktrace: true,
           show_sensitive_data_on_connection_error: true,
           pool_size: 5
         ]

# Defaults for the seeded "default" tenant (the tenant name Fineract's tests expect).
config :ecb_platform, :default_tenant,
  identifier: "default",
  name: "Default",
  db_name: "ecb_default"

config :ecb_web, ECBWeb.Endpoint,
  # Loopback only. Use ip: {0, 0, 0, 0} deliberately if other machines must reach it.
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "24000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "0Wbu607d+0ST8gHkf7NAM7hfAYYxC4af64JyAFNRcHAegk26tFZypOaDzMxtKwvf",
  # Set ECB_NO_WATCHERS=1 to run the server without the asset watchers (no esbuild or tailwind download).
  watchers:
    if(System.get_env("ECB_NO_WATCHERS"),
      do: [],
      else: [
        esbuild: {Esbuild, :install_and_run, [:ecb_web, ~w(--sourcemap=inline --watch)]},
        tailwind: {Tailwind, :install_and_run, [:ecb_web, ~w(--watch)]}
      ]
    ),
  live_reload: [
    patterns: [
      ~r"apps/ecb_web/priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/ecb_web/priv/gettext/.*(po)$",
      ~r"apps/ecb_web/lib/ecb_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :ecb_web, dev_routes: true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false
