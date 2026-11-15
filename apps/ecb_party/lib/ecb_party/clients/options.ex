defmodule ECBParty.Clients.Options do
  @moduledoc """
  The lists a client form offers: offices, staff, code values and savings products. Follows
  `ClientTemplateReadPlatformServiceImpl`. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBOrg.{Codes, Offices}
  alias ECBParty.Lookups
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @doc "The offices the user may pick, by hierarchy."
  @spec offices(User.t()) :: [map]
  def offices(%User{} = user), do: Offices.template(user).allowed_parents

  @doc """
  Staff the form offers for `office_id`: those of the office and of the offices above it (the whole
  list, by last name), or with `office_only` just the office's own as `%{id:, display_name:}`.
  """
  @spec staff(User.t(), integer, boolean) :: [map]
  def staff(%User{} = user, office_id, true) do
    pattern = Offices.user_hierarchy_pattern(user)

    from(s in "m_staff",
      join: o in "m_office",
      on: o.id == s.office_id,
      where: s.office_id == ^office_id and s.is_active == true and like(o.hierarchy, ^pattern),
      select: %{id: s.id, display_name: s.display_name}
    )
    |> TenantRepo.all()
  end

  def staff(%User{}, office_id, false) do
    from(o in "m_office",
      join: h in "m_office",
      on: fragment("? LIKE concat(?, '%')", o.hierarchy, h.hierarchy),
      join: s in "m_staff",
      on: s.office_id == h.id and s.is_active == true,
      where: o.id == ^office_id,
      order_by: s.lastname,
      select: %{
        id: s.id,
        office_id: s.office_id,
        office_name: h.name,
        firstname: s.firstname,
        lastname: s.lastname,
        display_name: s.display_name,
        is_loan_officer: s.is_loan_officer,
        external_id: s.external_id,
        mobile_no: s.mobile_no,
        is_active: s.is_active,
        joining_date: s.joining_date
      }
    )
    |> TenantRepo.all()
  end

  @doc "The values of the code named `name`, by position, as the maps `ECBOrg.Codes.values/2` gives (none if there is no such code)."
  @spec code_values(String.t()) :: [map]
  def code_values(name) do
    case Codes.get_by_name(name) do
      {:ok, code} -> Codes.values(code.id)
      {:error, _} -> []
    end
  end

  @doc "Savings products to choose from; none until the deposits module exists."
  @spec savings_products() :: [map]
  def savings_products do
    if Lookups.table?("m_savings_product") do
      TenantRepo.all(
        from(p in "m_savings_product", order_by: p.name, select: %{id: p.id, name: p.name})
      )
    else
      []
    end
  end
end
