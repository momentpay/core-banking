defmodule ECBPlatform.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants) do
      add :identifier, :string, null: false
      add :name, :string, null: false
      add :timezone_id, :string, null: false, default: "UTC"
      add :db_host, :string, null: false, default: "localhost"
      add :db_port, :integer, null: false, default: 5432
      add :db_name, :string, null: false
      add :db_username, :string, null: false, default: "postgres"
      # Name of the environment variable holding the password. The password is never stored.
      add :db_password_env, :string
      add :pool_size, :integer, null: false, default: 10

      timestamps()
    end

    create unique_index(:tenants, [:identifier])
  end
end
