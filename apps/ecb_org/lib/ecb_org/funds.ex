defmodule ECBOrg.Funds do
  @moduledoc "Funds (`m_fund`), read side. Must run inside a tenant scope."
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "Every fund, by name."
  @spec list() :: [map]
  def list do
    base()
    |> order_by([f], asc: fragment("? COLLATE \"C\"", f.name))
    |> TenantRepo.all()
  end

  @doc "One fund, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([f], f.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      fund -> {:ok, fund}
    end
  end

  @doc "Like `get/1` but raises the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, fund} -> fund
      {:error, error} -> raise error
    end
  end

  defp base,
    do: from(f in "m_fund", select: %{id: f.id, name: f.name, external_id: f.external_id})

  defp not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.fund.id.invalid",
        "Fund with identifier #{id} does not exist",
        [id]
      )
end
