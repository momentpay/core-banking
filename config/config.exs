# Shared configuration for every app in the E-CoreBank umbrella.
# Environment-specific files are imported at the bottom.
import Config

# --- ecb_platform ---------------------------------------------------------

config :ecb_platform,
  ecto_repos: [ECBPlatform.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# ECBPlatform.Repo is the tenant *registry* database: it knows which tenants exist
# and where each tenant's own database lives. Business data lives in per-tenant
# databases reached through ECBPlatform.TenantRepo (one database per tenant, as in
# Apache Fineract).
config :ecb_platform, ECBPlatform.Repo,
  migration_primary_key: [name: :id, type: :bigserial],
  migration_timestamps: [type: :utc_datetime_usec]

config :ecb_platform, ECBPlatform.TenantRepo,
  migration_primary_key: [name: :id, type: :bigserial],
  migration_timestamps: [type: :utc_datetime_usec]

# By default the mailer stores emails locally ("/dev/mailbox" in development).
# Production adapters are configured in config/runtime.exs.
config :ecb_platform, ECBPlatform.Mailer, adapter: Swoosh.Adapters.Local

# --- ecb_web --------------------------------------------------------------

config :ecb_web,
  generators: [context_app: :ecb_platform]

config :ecb_web, ECBWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ECBWeb.ErrorHTML, json: ECBWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ECBPlatform.PubSub,
  live_view: [signing_salt: "T2khpiNc"]

config :esbuild,
  version: "0.17.11",
  ecb_web: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/ecb_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  ecb_web: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/ecb_web/assets", __DIR__)
  ]

# --- shared ---------------------------------------------------------------

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Must remain at the bottom so it overrides the configuration above.
import_config "#{config_env()}.exs"
