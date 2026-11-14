defmodule ECBOrg.PaymentTypes do
  @moduledoc "Payment types (`m_payment_type`), read side. Must run inside a tenant scope."
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Every payment type, in position then id order."
  @spec list() :: [map]
  def list do
    from(p in "m_payment_type",
      order_by: [p.order_position, p.id],
      select: %{
        id: p.id,
        name: p.value,
        description: p.description,
        is_cash_payment: p.is_cash_payment,
        position: p.order_position,
        code_name: p.code_name,
        is_system_defined: p.is_system_defined
      }
    )
    |> TenantRepo.all()
  end
end
