defmodule Mix.Tasks.Ecb.Tenant.Migrate do
  @shortdoc "Creates (if needed) and migrates tenant databases"
  @moduledoc """
  Creates each tenant database if it does not exist and applies pending tenant migrations.

      mix ecb.tenant.migrate            # every tenant in the registry
      mix ecb.tenant.migrate default    # one tenant, by identifier
  """
  use Mix.Task

  alias ECBPlatform.Tenancy

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    tenants =
      case args do
        [] ->
          Tenancy.list_tenants()

        identifiers ->
          Enum.map(identifiers, fn identifier ->
            Tenancy.get_by_identifier(identifier) ||
              Mix.raise("Unknown tenant #{inspect(identifier)}")
          end)
      end

    Enum.each(tenants, fn tenant ->
      case Tenancy.migrate(tenant) do
        :ok -> Mix.shell().info("Migrated tenant #{tenant.identifier} (#{tenant.db_name}).")
        {:error, reason} -> Mix.raise("Tenant #{tenant.identifier} failed: #{inspect(reason)}")
      end
    end)
  end
end
