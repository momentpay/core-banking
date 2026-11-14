defmodule ECBOrg.PaymentTypes do
  @moduledoc "Payment types (`m_payment_type`), read side. Must run inside a tenant scope."
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "Every payment type, in position then id order."
  @spec list() :: [map]
  def list, do: base() |> order_by([p], [p.order_position, p.id]) |> TenantRepo.all()

  @doc "One payment type, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([p], p.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      payment_type -> {:ok, payment_type}
    end
  end

  @doc "Like `get/1` but raises the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, payment_type} -> payment_type
      {:error, error} -> raise error
    end
  end

  defp base do
    from p in "m_payment_type",
      select: %{
        id: p.id,
        name: p.value,
        description: p.description,
        is_cash_payment: p.is_cash_payment,
        position: p.order_position,
        code_name: p.code_name,
        is_system_defined: p.is_system_defined
      }
  end

  defp not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.payment.type.invalid",
        "PaymentType with #{id} does not exist",
        [id]
      )
end
