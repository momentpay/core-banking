defmodule ECBPlatform.Tenancy do
  @moduledoc """
  Tenant registry and tenant scoping (one database per tenant, as in Apache Fineract).

  Every request or job that touches business data runs inside `with_tenant/2`:

      Tenancy.with_tenant("default", fn ->
        ECBPlatform.TenantRepo.all(...)
      end)

  The tenant identifier comes from the `Fineract-Platform-TenantId` header on the
  compatible API and from our own header on the native API.
  """
  import Ecto.Query, only: [from: 2]

  alias ECBPlatform.Repo
  alias ECBPlatform.Tenancy.{Pools, Tenant}
  alias ECBPlatform.TenantRepo

  @spec list_tenants() :: [Tenant.t()]
  def list_tenants, do: Repo.all(from t in Tenant, order_by: t.identifier)

  @spec get_by_identifier(String.t()) :: Tenant.t() | nil
  def get_by_identifier(identifier), do: Repo.get_by(Tenant, identifier: identifier)

  @spec create_tenant(map) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    %Tenant{} |> Tenant.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Runs `fun` with `ECBPlatform.TenantRepo` pointed at the tenant's database.

  Returns `{:ok, result}`, `{:error, :unknown_tenant}`, or `{:error, reason}` if the
  tenant's pool could not be started. The previous scope is restored afterwards, so calls
  can nest.
  """
  @spec with_tenant(String.t() | Tenant.t(), (-> result)) ::
          {:ok, result} | {:error, :unknown_tenant | term}
        when result: term
  def with_tenant(identifier, fun) when is_binary(identifier) and is_function(fun, 0) do
    case get_by_identifier(identifier) do
      nil -> {:error, :unknown_tenant}
      tenant -> with_tenant(tenant, fun)
    end
  end

  def with_tenant(%Tenant{} = tenant, fun) when is_function(fun, 0) do
    with {:ok, pool} <- Pools.ensure_started(tenant) do
      previous = TenantRepo.put_dynamic_repo(pool)

      try do
        {:ok, fun.()}
      after
        TenantRepo.put_dynamic_repo(previous)
      end
    end
  end

  @doc """
  Points the calling process at a tenant's database until the process ends (or `activate/1` is called
  again). For a request process, which handles one request for one tenant, where wrapping everything
  in `with_tenant/2` would be awkward. Returns `:ok` or `{:error, reason}`.
  """
  @spec activate(Tenant.t()) :: :ok | {:error, term}
  def activate(%Tenant{} = tenant) do
    with {:ok, pool} <- Pools.ensure_started(tenant) do
      TenantRepo.put_dynamic_repo(pool)
      :ok
    end
  end

  @doc """
  Directories of the migrations applied to every tenant database: `priv/tenant_repo/migrations` of
  every `ecb_*` app. Each domain app brings its own tables, and all of them run in version order.
  """
  @spec tenant_migration_paths() :: [String.t()]
  def tenant_migration_paths do
    load_umbrella_apps()

    for {app, _description, _version} <- Application.loaded_applications(),
        String.starts_with?(Atom.to_string(app), "ecb_"),
        dir = Path.join(to_string(:code.priv_dir(app)), "tenant_repo/migrations"),
        File.dir?(dir),
        do: dir
  end

  # Run from one app's folder (`cd apps/ecb_platform && mix ecto.setup`), Mix puts only that app and its
  # dependencies on the code path, so the other apps' migrations would be missed. Load every `ecb_*` app
  # that has been built, so all of their `priv/tenant_repo/migrations` are found.
  defp load_umbrella_apps do
    if Code.ensure_loaded?(Mix.Project) do
      build_lib = Path.join(Mix.Project.build_path(), "lib")

      for dir <- Path.wildcard(Path.join(build_lib, "ecb_*")),
          File.dir?(Path.join(dir, "ebin")) do
        Code.prepend_path(Path.join(dir, "ebin"))
        dir |> Path.basename() |> String.to_atom() |> Application.load()
      end
    end

    :ok
  end

  @doc """
  Creates the tenant's database if it does not exist, then applies all pending tenant migrations.

  Runs on a connection of its own (not the shared pool), because migrating is an administrative
  operation and must not depend on how the shared pool is configured.
  """
  @spec migrate(Tenant.t()) :: :ok | {:error, term}
  def migrate(%Tenant{} = tenant) do
    storage_opts = Tenant.repo_opts(tenant)

    case TenantRepo.__adapter__().storage_up(storage_opts) do
      :ok -> run_migrations(storage_opts)
      {:error, :already_up} -> run_migrations(storage_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_migrations(opts) do
    {:ok, pid} =
      TenantRepo.start_link(
        Keyword.merge(opts, name: nil, pool_size: 2, pool: DBConnection.ConnectionPool)
      )

    try do
      Ecto.Migrator.run(TenantRepo, tenant_migration_paths(), :up, all: true, dynamic_repo: pid)
      :ok
    after
      Supervisor.stop(pid)
    end
  end
end
