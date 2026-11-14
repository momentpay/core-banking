defmodule ECBPlatform.TenancyTest do
  use ECBPlatform.DataCase, async: true

  alias ECBPlatform.Tenancy
  alias ECBPlatform.Tenancy.Tenant
  alias ECBPlatform.TenantRepo

  # The tenant under test points at the registry's own test database. That is enough to prove
  # the dynamic-repo mechanics without needing a second database in CI.
  defp tenant_attrs(identifier) do
    config = ECBPlatform.Repo.config()

    %{
      identifier: identifier,
      name: "Test #{identifier}",
      db_host: config[:hostname],
      db_port: config[:port],
      db_name: config[:database],
      db_username: config[:username],
      pool_size: 2
    }
  end

  describe "registry" do
    test "creates and finds a tenant by identifier" do
      assert {:ok, %Tenant{identifier: "alpha"}} = Tenancy.create_tenant(tenant_attrs("alpha"))
      assert %Tenant{name: "Test alpha"} = Tenancy.get_by_identifier("alpha")
      assert Tenancy.get_by_identifier("missing") == nil
    end

    test "rejects a duplicate identifier" do
      assert {:ok, _} = Tenancy.create_tenant(tenant_attrs("beta"))
      assert {:error, changeset} = Tenancy.create_tenant(tenant_attrs("beta"))
      assert "has already been taken" in errors_on(changeset).identifier
    end

    test "rejects identifiers and database names that are not plain identifiers" do
      attrs = %{tenant_attrs("gamma") | db_name: "x\"; DROP DATABASE y; --"}
      assert {:error, changeset} = Tenancy.create_tenant(attrs)
      assert "has invalid format" in errors_on(changeset).db_name

      assert {:error, changeset} = Tenancy.create_tenant(tenant_attrs("Bad Id"))
      assert "has invalid format" in errors_on(changeset).identifier
    end

    test "never stores a password" do
      refute :db_password in Tenant.__schema__(:fields)
    end
  end

  describe "with_tenant/2" do
    test "runs the function against the tenant's database" do
      {:ok, tenant} = Tenancy.create_tenant(tenant_attrs("delta"))

      assert {:ok, %Postgrex.Result{rows: [[1]]}} =
               Tenancy.with_tenant(tenant.identifier, fn -> TenantRepo.query!("SELECT 1") end)
    end

    test "returns an error for an unknown tenant" do
      assert {:error, :unknown_tenant} = Tenancy.with_tenant("nope", fn -> :unreachable end)
    end

    test "restores the previous scope even when the function raises" do
      {:ok, tenant} = Tenancy.create_tenant(tenant_attrs("epsilon"))
      before_scope = TenantRepo.get_dynamic_repo()

      assert_raise RuntimeError, "boom", fn ->
        Tenancy.with_tenant(tenant, fn -> raise "boom" end)
      end

      assert TenantRepo.get_dynamic_repo() == before_scope
    end

    test "reuses one pool per tenant" do
      {:ok, tenant} = Tenancy.create_tenant(tenant_attrs("zeta"))
      {:ok, pool1} = ECBPlatform.Tenancy.Pools.ensure_started(tenant)
      {:ok, pool2} = ECBPlatform.Tenancy.Pools.ensure_started(tenant)
      assert pool1 == pool2
    end
  end
end
