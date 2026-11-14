defmodule ECBOrg.PaymentTypes.Write do
  @moduledoc """
  Creating, changing and deleting payment types (`m_payment_type`).

  Fineract 1.16 handles payment types with its newer typed commands: an update replaces the stored
  values with the request, and the answer carries only the `resourceId`. E-CoreBank keeps those
  answers. Where that release answers HTTP 500 for a request without a name, or an unknown parameter,
  this module answers a validation error (see docs/divergences.md).
  """
  import Ecto.Query

  alias ECBOrg.PaymentTypes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.{Integrity, Params, TenantRepo, Validation}

  @supported ~w(name description isCashPayment position codeName isSystemDefined)

  @doc "Creates the payment type `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    params = Params.check_supported!(params, @supported)
    validate!(params, true)

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_payment_type",
        [
          %{
            value: String.trim(Params.string(params, "name")),
            description: Params.string(params, "description"),
            is_cash_payment: Params.boolean(params, "isCashPayment"),
            order_position: Params.long(params, "position") || 0,
            code_name: Params.string(params, "codeName"),
            is_system_defined: Params.boolean(params, "isSystemDefined") || false
          }
        ],
        returning: [:id]
      )

    Result.new(resource_id: id)
  end

  @doc "Changes payment type `id`: only the values the request carries are replaced."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    params = Params.check_supported!(params, @supported)
    validate!(params, false)
    _existing = PaymentTypes.fetch!(id)

    set =
      for {key, column, reader} <- [
            {"name", :value, &trimmed/2},
            {"description", :description, &Params.string/2},
            {"isCashPayment", :is_cash_payment, &Params.boolean/2},
            {"position", :order_position, &Params.long/2},
            {"codeName", :code_name, &Params.string/2},
            {"isSystemDefined", :is_system_defined, &Params.boolean/2}
          ],
          Params.exists?(params, key),
          do: {column, reader.(params, key)}

    unless set == [] do
      TenantRepo.update_all(from(p in "m_payment_type", where: p.id == ^id), set: set)
    end

    Result.new(resource_id: id)
  end

  @doc "Deletes payment type `id`; refused while something refers to it."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    _existing = PaymentTypes.fetch!(id)

    Integrity.translate(
      fn -> TenantRepo.delete_all(from(p in "m_payment_type", where: p.id == ^id)) end,
      %{},
      {"error.msg.payment.type.association.exist", "cannot.delete.payment.type.with.association"}
    )

    Result.new(resource_id: id)
  end

  defp trimmed(params, key), do: params |> Params.string(key) |> String.trim()

  # A name is needed to create; on update it only has to be valid when sent.
  defp validate!(params, creating?) do
    validation = Validation.new("paymenttype")

    validation =
      if creating? or Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank()
          |> Validation.max_length(100),
        else: validation

    validation
    |> Validation.param("description", Params.string(params, "description"))
    |> Validation.max_length(500)
    |> Validation.param("codeName", Params.string(params, "codeName"))
    |> Validation.max_length(100)
    |> Validation.param("position", Params.long(params, "position"))
    |> Validation.zero_or_greater()
    |> Validation.raise_if_errors!()
  end
end
