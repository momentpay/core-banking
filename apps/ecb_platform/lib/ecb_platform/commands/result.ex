defmodule ECBPlatform.Commands.Result do
  @moduledoc """
  What a command handler returns: the ids of what it created or changed, and the fields that changed.

  Mirrors `CommandProcessingResult`. The API answer and the stored result use Fineract's field names
  (`resourceId`, `officeId`, `changes`, ...) and leave out fields that are not set.
  """

  defstruct [
    :command_id,
    :office_id,
    :group_id,
    :client_id,
    :loan_id,
    :savings_id,
    :resource_id,
    :subresource_id,
    :transaction_id,
    :changes,
    :credit_bureau_report_data,
    :resource_identifier,
    :product_id,
    :gsim_id,
    :glim_id,
    :resource_external_id,
    :subresource_external_id,
    :loan_external_id,
    rollback_transaction: false
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds a result from keyword options named as the fields. When `:resource_id` is given and
  `:resource_identifier` is not, the identifier is the id as text, as in Fineract.
  """
  @spec new(keyword) :: t()
  def new(opts \\ []) do
    result = struct!(__MODULE__, opts)

    if result.resource_id && is_nil(result.resource_identifier),
      do: %{result | resource_identifier: Integer.to_string(result.resource_id)},
      else: result
  end

  @json_keys [
    command_id: "commandId",
    office_id: "officeId",
    group_id: "groupId",
    client_id: "clientId",
    loan_id: "loanId",
    savings_id: "savingsId",
    resource_id: "resourceId",
    subresource_id: "subResourceId",
    transaction_id: "transactionId",
    changes: "changes",
    credit_bureau_report_data: "creditBureauReportData",
    resource_identifier: "resourceIdentifier",
    product_id: "productId",
    gsim_id: "gsimId",
    glim_id: "glimId",
    resource_external_id: "resourceExternalId",
    subresource_external_id: "subResourceExternalId",
    loan_external_id: "loanExternalId"
  ]

  @doc "The map sent to API clients: Fineract's field names, unset fields left out."
  @spec to_api_map(t()) :: map
  def to_api_map(%__MODULE__{} = result) do
    for {field, key} <- @json_keys,
        value = Map.fetch!(result, field),
        value != nil,
        into: %{},
        do: {key, value}
  end

  @doc "The result as stored with the command (JSON text)."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = result), do: result |> to_api_map() |> Jason.encode!()
end
