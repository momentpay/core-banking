defmodule ECBPlatform.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:ecb_platform, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ECBPlatform.PubSub},
      # HTTP client used by the mailer.
      {Finch, name: ECBPlatform.Finch},
      # Tenant registry database.
      ECBPlatform.Repo,
      # One connection pool per tenant database, started on demand.
      {DynamicSupervisor, name: ECBPlatform.Tenancy.PoolSupervisor, strategy: :one_for_one},
      ECBPlatform.Tenancy.Pools
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ECBPlatform.Supervisor)
  end
end
