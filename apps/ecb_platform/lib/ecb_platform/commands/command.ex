defmodule ECBPlatform.Commands.Command do
  @moduledoc """
  A request to change something: what Fineract splits into `CommandWrapper` (which action on which
  entity, with the ids that locate it) and `JsonCommand` (the request body).

  `json` is the body exactly as received. It is stored as text with the command and compared as text
  when looking for a pending duplicate, so it is never re-encoded. `data/1` parses it for handlers.

  Entity and action names are Fineract's (`"CLIENT"`, `"CREATE"`, `"ACTIVATE"`, ...). The permission
  needed is `"<ACTION>_<ENTITY>"`, for example `"CREATE_CLIENT"`.
  """

  @enforce_keys [:action_name, :entity_name]
  defstruct [
    :action_name,
    :entity_name,
    :entity_id,
    :subentity_id,
    :href,
    :json,
    :office_id,
    :group_id,
    :client_id,
    :loan_id,
    :savings_id,
    :product_id,
    :transaction_id,
    :credit_bureau_id,
    :organisation_credit_bureau_id,
    :job_name,
    :loan_external_id,
    :resource_external_id,
    :subresource_external_id,
    :idempotency_key,
    :command_source_id,
    :client_ip
  ]

  @type t :: %__MODULE__{
          action_name: String.t(),
          entity_name: String.t(),
          entity_id: integer | nil,
          subentity_id: integer | nil,
          href: String.t() | nil,
          json: String.t() | nil,
          idempotency_key: String.t() | nil,
          command_source_id: integer | nil
        }

  @doc """
  Builds a command. All other fields are optional keyword options, named as the struct fields.

      Command.new("CREATE", "CLIENT", json: ~s({"firstname":"Ada"}), office_id: 1)
  """
  @spec new(String.t(), String.t(), keyword) :: t()
  def new(action_name, entity_name, opts \\ [])
      when is_binary(action_name) and is_binary(entity_name) do
    struct!(__MODULE__, Keyword.merge(opts, action_name: action_name, entity_name: entity_name))
  end

  @doc "The permission code needed to run the command: `\"<ACTION>_<ENTITY>\"`."
  @spec task_permission(t()) :: String.t()
  def task_permission(%__MODULE__{action_name: action, entity_name: entity}),
    do: action <> "_" <> entity

  @doc "The request body parsed as a map. An empty or missing body is an empty map."
  @spec data(t()) :: map
  def data(%__MODULE__{json: nil}), do: %{}
  def data(%__MODULE__{json: ""}), do: %{}
  def data(%__MODULE__{json: json}), do: Jason.decode!(json)

  @doc "The body as stored: a missing body is stored as `{}`, as Fineract does."
  @spec stored_json(t()) :: String.t()
  def stored_json(%__MODULE__{json: nil}), do: "{}"
  def stored_json(%__MODULE__{json: json}), do: json
end
