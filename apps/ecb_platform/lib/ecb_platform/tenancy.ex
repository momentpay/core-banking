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

  @doc "Directory of the migrations applied to every tenant database."
  def tenant_migrations_path,
    do: Application.app_dir(:ecb_platform, "priv/tenant_repo/migrations")

  @doc """
  Creates the tenant's database if it does not exist, then applies all tenant migrations.
  """
  @spec migrate(Tenant.t()) :: :ok | {:error, term}
  def migrate(%Tenant{} = tenant) do
    storage_opts = Tenant.repo_opts(tenant)

    case TenantRepo.__adapter__().storage_up(storage_opts) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> throw({:storage_up_failed, reason})
    end

    with {:ok, pool} <- Pools.ensure_started(tenant) do
      Ecto.Migrator.run(TenantRepo, tenant_migrations_path(), :up,
        all: true,
        dynamic_repo: pool
      )

      :ok
    end
  catch
    {:storage_up_failed, reason} -> {:error, reason}
  end
end
