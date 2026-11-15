defmodule ECBLedger.Closures do
  @moduledoc """
  Accounting closures (`acc_gl_closure`), read side, following Fineract's `GLClosureReadPlatformServiceImpl`.

  A closure says that nothing may be posted to (or reversed in) an office on or before its closing date.
  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "The closures, latest closing date first; of one office when `office_id` is given and not zero."
  @spec list(integer | nil) :: [map]
  def list(office_id \\ nil) do
    base()
    |> where([c], c.is_deleted == false)
    |> for_office(office_id)
    |> order_by([c], desc: c.closing_date, asc: c.id)
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc "One closure, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([c], c.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "Like `get/1` but raises the error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, closure} -> closure
      {:error, error} -> raise error
    end
  end

  @doc "The latest closing date of an office, or `nil` when it has no closure."
  @spec latest_date(integer) :: Date.t() | nil
  def latest_date(office_id),
    do:
      TenantRepo.one(
        from c in "acc_gl_closure", where: c.office_id == ^office_id, select: max(c.closing_date)
      )

  @doc """
  The date up to which postings to an office are closed, or `nil`. A posting dated on or before it is
  refused.
  """
  @spec closed_until(integer) :: Date.t() | nil
  def closed_until(office_id), do: latest_date(office_id)

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.glclosure.id.invalid",
        "Accounting Closure with identifier #{id} does not exist",
        [id]
      )

  defp for_office(query, office_id) when office_id in [nil, 0], do: query
  defp for_office(query, office_id), do: where(query, [c], c.office_id == ^office_id)

  defp base do
    from c in "acc_gl_closure",
      join: o in "m_office",
      on: o.id == c.office_id,
      join: creator in "m_appuser",
      on: creator.id == c.createdby_id,
      join: updater in "m_appuser",
      on: updater.id == c.lastmodifiedby_id,
      select: %{
        id: c.id,
        office_id: o.id,
        office_name: o.name,
        closing_date: c.closing_date,
        deleted: c.is_deleted,
        created_date: c.created_date,
        updated_date: c.lastmodified_date,
        created_by_id: creator.id,
        created_by_name: creator.username,
        updated_by_id: updater.id,
        updated_by_name: updater.username,
        comments: c.comments
      }
  end

  defp finish(row) do
    %{
      row
      | created_date: to_date(row.created_date),
        updated_date: to_date(row.updated_date)
    }
  end

  defp to_date(nil), do: nil
  defp to_date(%NaiveDateTime{} = at), do: NaiveDateTime.to_date(at)
end
