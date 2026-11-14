defmodule ECBPlatform.Commands.CommandSource do
  @moduledoc """
  A command as it is stored: the row in `m_portfolio_command_source`, Fineract's audit trail of every
  state-changing request. It records who made the request, who checked it, what was asked, what came
  back, and the idempotency key that makes the request safe to repeat.

  Same table and columns as Fineract. The pair (`action_name`, `entity_name`, `idempotency_key`) is
  unique, which is how a repeated request is recognised.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ECBPlatform.Commands.ResultType

  @primary_key {:id, :id, autogenerate: true}
  schema "m_portfolio_command_source" do
    field :action_name, :string
    field :entity_name, :string
    field :office_id, :integer
    field :group_id, :integer
    field :client_id, :integer
    field :loan_id, :integer
    field :savings_account_id, :integer
    field :api_get_url, :string
    field :resource_id, :integer
    field :subresource_id, :integer
    field :command_as_json, :string
    field :maker_id, :integer
    field :made_on_date, :naive_datetime
    field :checker_id, :integer
    field :checked_on_date, :naive_datetime
    field :status, :integer
    field :product_id, :integer
    field :transaction_id, :string
    field :creditbureau_id, :integer
    field :organisation_creditbureau_id, :integer
    field :made_on_date_utc, :utc_datetime_usec
    field :checked_on_date_utc, :utc_datetime_usec
    field :job_name, :string
    field :idempotency_key, :string
    field :resource_external_id, :string
    field :subresource_external_id, :string
    field :result, :string
    field :result_status_code, :integer
    field :loan_external_id, :string
    field :is_sanitized, :boolean, default: false
    field :client_ip, :string
  end

  @doc "The status as an atom."
  @spec result_type(%__MODULE__{}) :: ResultType.t()
  def result_type(%__MODULE__{status: status}), do: ResultType.from_int(status)

  @doc "The permission code of the stored command: `\"<ACTION>_<ENTITY>\"`."
  @spec permission_code(%__MODULE__{}) :: String.t()
  def permission_code(%__MODULE__{action_name: action, entity_name: entity}),
    do: action <> "_" <> entity

  @doc "Changeset for the first save, before the handler runs."
  def initial_changeset(source, attrs) do
    source
    |> cast(attrs, __schema__(:fields) -- [:id])
    |> validate_required([
      :action_name,
      :entity_name,
      :api_get_url,
      :command_as_json,
      :maker_id,
      :made_on_date_utc,
      :status,
      :idempotency_key
    ])
    |> validate_length(:idempotency_key, max: 50)
    |> unique_constraint(:idempotency_key, name: :unique_portfolio_command_source)
  end

  @doc "Changeset for recording a result, an error, a checker or a new status."
  def result_changeset(source, attrs) do
    cast(
      source,
      attrs,
      __schema__(:fields) -- [:id, :maker_id, :made_on_date_utc, :idempotency_key]
    )
  end
end
