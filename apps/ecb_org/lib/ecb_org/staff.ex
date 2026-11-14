defmodule ECBOrg.Staff do
  @moduledoc """
  Staff members (`m_staff`), read side. As in Fineract, a user sees the staff of the offices at or
  below their own in the hierarchy, and only active staff unless another status is asked for. Must run
  inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @doc """
  Staff the user can see, by display name. Options: `:office_id`, `:loan_officers_only` and
  `:status` (`"active"` (the default), `"inactive"` or `"all"`).
  """
  @spec list(User.t(), keyword) :: [map]
  def list(%User{} = user, opts \\ []) do
    pattern = hierarchy_of(user) <> "%"

    base()
    |> where([s, o], like(o.hierarchy, ^pattern))
    |> order_by([s], asc: fragment("? COLLATE \"C\"", s.display_name), asc: s.id)
    |> filter_office(opts[:office_id])
    |> filter_loan_officers(opts[:loan_officers_only])
    |> filter_status(opts[:status] || "active")
    |> TenantRepo.all()
  end

  @doc "One staff member, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([s], s.id == ^id) |> TenantRepo.one() do
      nil ->
        {:error,
         ResourceNotFound.new(
           "error.msg.staff.id.invalid",
           "Staff with identifier #{id} does not exist",
           [id]
         )}

      staff ->
        {:ok, staff}
    end
  end

  @doc "Like `get/1` but raises the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, staff} -> staff
      {:error, error} -> raise error
    end
  end

  defp base do
    from s in "m_staff",
      join: o in "m_office",
      on: o.id == s.office_id,
      select: %{
        id: s.id,
        firstname: s.firstname,
        lastname: s.lastname,
        display_name: s.display_name,
        office_id: s.office_id,
        office_name: o.name,
        is_loan_officer: s.is_loan_officer,
        external_id: s.external_id,
        mobile_no: s.mobile_no,
        email_address: s.email_address,
        is_active: s.is_active,
        joining_date: s.joining_date
      }
  end

  defp filter_office(query, nil), do: query
  defp filter_office(query, id), do: where(query, [s], s.office_id == ^id)

  defp filter_loan_officers(query, true), do: where(query, [s], s.is_loan_officer == true)
  defp filter_loan_officers(query, _), do: query

  defp filter_status(query, "active"), do: where(query, [s], s.is_active == true)
  defp filter_status(query, "inactive"), do: where(query, [s], s.is_active == false)
  defp filter_status(query, _), do: query

  defp hierarchy_of(%User{office_id: nil}), do: "."

  defp hierarchy_of(%User{office_id: office_id}),
    do:
      TenantRepo.one(from o in "m_office", where: o.id == ^office_id, select: o.hierarchy) || "."
end
