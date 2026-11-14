defmodule ECBApiFineract.Resources.PaymentTypes do
  @moduledoc "`/v1/paymenttypes`: list, one payment type, create, update and delete."
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.PaymentTypes

  @doc "`GET /paymenttypes`"
  def index(conn) do
    Read.respond(conn, "PAYMENTTYPE", fn -> Enum.map(PaymentTypes.list(), &serialize/1) end)
  end

  @doc "`GET /paymenttypes/:id`"
  def show(conn, raw_id) do
    Read.respond(conn, "PAYMENTTYPE", fn ->
      with {:ok, id} <- Write.id(raw_id, &not_found/1),
           {:ok, payment_type} <- PaymentTypes.get(id),
           do: serialize(payment_type)
    end)
  end

  @doc "`POST /paymenttypes`"
  def create(conn), do: Write.execute(conn, "PAYMENTTYPE", "CREATE")

  @doc "`PUT /paymenttypes/:id`"
  def update(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &not_found/1,
        &Write.execute(conn, "PAYMENTTYPE", "UPDATE", id: &1)
      )

  @doc "`DELETE /paymenttypes/:id`"
  def delete(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &not_found/1,
        &Write.execute(conn, "PAYMENTTYPE", "DELETE", id: &1)
      )

  defp serialize(p) do
    %{
      "id" => p.id,
      "name" => p.name,
      "description" => p.description,
      "isCashPayment" => p.is_cash_payment,
      "position" => p.position,
      "codeName" => p.code_name,
      "isSystemDefined" => p.is_system_defined
    }
  end

  defp not_found(raw),
    do:
      ECBPlatform.Errors.ResourceNotFound.new(
        "error.msg.payment.type.invalid",
        "PaymentType with #{raw} does not exist",
        [raw]
      )
end
