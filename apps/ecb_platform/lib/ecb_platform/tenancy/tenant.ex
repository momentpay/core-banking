defmodule ECBPlatform.Tenancy.Tenant do
  @moduledoc """
  A tenant (a bank, or one bank's environment) and the location of its database.

  The database password is never stored here. `db_password_env` names the environment
  variable that holds it. When it is `nil`, `ECB_DB_PASSWORD` is used.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tenants" do
    field :identifier, :string
    field :name, :string
    field :timezone_id, :string, default: "UTC"
    field :db_host, :string, default: "localhost"
    field :db_port, :integer, default: 5432
    field :db_name, :string
    field :db_username, :string, default: "postgres"
    field :db_password_env, :string
    field :pool_size, :integer, default: 10

    timestamps()
  end

  @fields ~w(identifier name timezone_id db_host db_port db_name db_username db_password_env pool_size)a
  @required ~w(identifier name timezone_id db_host db_port db_name db_username pool_size)a

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, @fields)
    |> validate_required(@required)
    # The identifier travels in the Fineract-Platform-TenantId header.
    |> validate_format(:identifier, ~r/^[a-z][a-z0-9_-]{0,62}$/)
    # The database name is used in CREATE DATABASE, so keep it to plain identifier characters.
    |> validate_format(:db_name, ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,62}$/)
    |> validate_format(:db_password_env, ~r/^[A-Z_][A-Z0-9_]*$/)
    |> validate_number(:db_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:pool_size, greater_than: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:identifier)
  end

  @doc "Connection options for `ECBPlatform.TenantRepo`. Reads the password from the environment."
  def repo_opts(%__MODULE__{} = tenant) do
    [
      hostname: tenant.db_host,
      port: tenant.db_port,
      database: tenant.db_name,
      username: tenant.db_username,
      password: password(tenant),
      pool_size: tenant.pool_size
    ]
  end

  defp password(%__MODULE__{db_password_env: nil}), do: System.get_env("ECB_DB_PASSWORD")
  defp password(%__MODULE__{db_password_env: name}), do: System.get_env(name)
end
