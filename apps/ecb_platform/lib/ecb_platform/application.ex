defmodule ECBPlatform.Application do
  @moduledoc false

  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"ROLE", "CREATE", ECBPlatform.Handlers.CreateRole},
    {"ROLE", "UPDATE", ECBPlatform.Handlers.UpdateRole},
    {"ROLE", "DELETE", ECBPlatform.Handlers.DeleteRole},
    {"ROLE", "ENABLE", ECBPlatform.Handlers.EnableRole},
    {"ROLE", "DISABLE", ECBPlatform.Handlers.DisableRole},
    {"ROLE", "PERMISSIONS", ECBPlatform.Handlers.UpdateRolePermissions},
    {"USER", "CREATE", ECBPlatform.Handlers.CreateUser},
    {"USER", "UPDATE", ECBPlatform.Handlers.UpdateUser},
    {"USER", "DELETE", ECBPlatform.Handlers.DeleteUser},
    {"USER", "CHANGEPWD", ECBPlatform.Handlers.ChangeUserPassword},
    {"CONFIGURATION", "UPDATE", ECBPlatform.Handlers.UpdateConfiguration},
    {"PASSWORD_PREFERENCES", "UPDATE", ECBPlatform.Handlers.UpdatePasswordPreferences},
    {"PERMISSION", "UPDATE", ECBPlatform.Handlers.UpdateMakerCheckerPermissions}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

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

    # starts the jobs by their cron expression, when switched on (ECB_SCHEDULER, see ECBPlatform.Scheduler)
    children =
      if ECBPlatform.Scheduler.enabled?(), do: children ++ [ECBPlatform.Scheduler], else: children

    Supervisor.start_link(children, strategy: :one_for_one, name: ECBPlatform.Supervisor)
  end
end
