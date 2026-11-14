import Config

config :ecb_web, ECBWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: ECBPlatform.Finch
config :swoosh, local: false

config :logger, level: :info

# Runtime production configuration, including reading of environment variables,
# is done in config/runtime.exs.
