defmodule ECBParty.Lookups do
  @moduledoc """
  The things a client refers to, looked up the way Fineract's repository wrappers look them up: each one
  that is missing is answered with its own "not found" error. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc """
  The code value `id` of the code named `code_name`, as `%{id:, name:}`. A value that does not exist, or
  belongs to another code, is `error.msg.codevalue.codename.id.combination.invalid`.
  """
  @spec code_value!(String.t(), integer) :: %{id: integer, name: String.t()}
  def code_value!(code_name, id) do
    row =
      TenantRepo.one(
        from(v in "m_code_value",
          join: c in "m_code",
          on: c.id == v.code_id,
          where: c.code_name == ^code_name and v.id == ^id,
          select: %{id: v.id, name: v.code_value}
        )
      )

    row ||
      raise ResourceNotFound,
        code: "error.msg.codevalue.codename.id.combination.invalid",
        message:
          "Code value with identifier #{id} does not exist for a code with name #{code_name}",
        args: [id, code_name]
  end

  @doc """
  Staff member `id`, who must work in the office of the given hierarchy or one above it. Anything else is
  `error.msg.staff.id.invalid`.
  """
  @spec staff!(integer, String.t()) :: %{id: integer, display_name: String.t()}
  def staff!(id, hierarchy) do
    row =
      TenantRepo.one(
        from(s in "m_staff",
          join: o in "m_office",
          on: o.id == s.office_id,
          where: s.id == ^id,
          select: %{id: s.id, display_name: s.display_name, office_hierarchy: o.hierarchy}
        )
      )

    if row && String.starts_with?(hierarchy, row.office_hierarchy) do
      row
    else
      raise ResourceNotFound,
        code: "error.msg.staff.id.invalid",
        message: "Staff with identifier #{id} does not exist",
        args: [id]
    end
  end

  @doc "The office `id`, or Fineract's office-not-found error."
  @spec office!(integer) :: map
  def office!(id) do
    case ECBOrg.Offices.get(id) do
      {:ok, office} -> office
      {:error, error} -> raise error
    end
  end

  @doc """
  A savings product that must exist. Savings products arrive with the deposits module; until then none
  does, so any id is refused.
  """
  @spec savings_product!(integer) :: :ok
  def savings_product!(id) do
    if table?("m_savings_product") and
         TenantRepo.exists?(from(p in "m_savings_product", where: p.id == ^id)) do
      :ok
    else
      raise ResourceNotFound,
        code: "error.msg.savingproduct.id.invalid",
        message: "Saving product with identifier #{id} does not exist",
        args: [id]
    end
  end

  @doc "A group that must exist. Groups are not built yet, so any id is refused."
  @spec group!(integer) :: no_return
  def group!(id) do
    raise ResourceNotFound,
      code: "error.msg.group.id.invalid",
      message: "Group with identifier #{id} does not exist",
      args: [id]
  end

  @doc "True when the tenant database has the table (modules that are not built yet have none)."
  @spec table?(String.t()) :: boolean
  def table?(name) do
    TenantRepo.query!("SELECT to_regclass($1) IS NOT NULL", [name]).rows == [[true]]
  end
end
