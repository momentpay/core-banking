import Config

# Executed for all environments, including releases, after compilation and before
# the system starts. Secrets are read from the environment, never committed.

if System.get_env("PHX_SERVER") do
  config :ecb_web, ECBWeb.Endpoint, server: true
end

# The scheduler starts the jobs (nightly accruals, arrears ageing...) by their cron expression. Switch it on in
# exactly the nodes that should do it; it is off in tests. Several nodes may run it: a job runs on one at a time.
if config_env() != :test do
  config :ecb_platform, ECBPlatform.Scheduler,
    enabled: System.get_env("ECB_SCHEDULER") in ~w(true 1)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      It points at the tenant registry database, for example:
      ecto://USER:PASS@HOST/ecb_tenants
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ecb_platform, ECBPlatform.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ecb_platform, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ecb_web, ECBWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
