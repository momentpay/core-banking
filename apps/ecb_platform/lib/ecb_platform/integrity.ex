defmodule ECBPlatform.Integrity do
  @moduledoc """
  Turns a rule the database enforces into the error Fineract reports for it.

  A write that breaks a unique constraint or a foreign key makes PostgreSQL refuse it. Fineract catches
  that and answers with a message about the thing the person did (a duplicate name, a record still in
  use) instead of a raw database error. Name the constraints you expect and what they mean:

      Integrity.translate(fn -> insert_office() end, %{
        "m_office_name_key" => {"error.msg.office.duplicate.name", "Office with name `X` already exists", "name", ["X"]}
      })

  A constraint that is not named is reported with the `unknown` code, never with database text.
  """
  alias ECBPlatform.Errors.DataIntegrity

  @other_integrity_codes [
    :string_data_right_truncation,
    :not_null_violation,
    :check_violation,
    :numeric_value_out_of_range
  ]

  @type rule ::
          {code :: String.t(), message :: String.t(), parameter :: String.t() | nil,
           args :: [term]}

  @doc """
  Runs `fun`. A unique-key or foreign-key violation of a constraint in `rules` raises the
  `DataIntegrity` error described for it; any other is raised as the generic error built from `unknown`
  (`{code, message}`).
  """
  @spec translate((-> result), %{String.t() => rule}, {String.t(), String.t()}) :: result
        when result: term
  def translate(fun, rules, unknown) do
    fun.()
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code, constraint: constraint}
        when code in [:unique_violation, :foreign_key_violation, :restrict_violation] ->
          reraise integrity_error(Map.get(rules, constraint), unknown), __STACKTRACE__

        # a value too long for its column, a missing required value, a number out of range: Fineract's
        # database layer reports every one of these as a data-integrity problem too
        %{code: code} when code in @other_integrity_codes ->
          reraise integrity_error(nil, unknown), __STACKTRACE__

        _ ->
          reraise error, __STACKTRACE__
      end
  end

  defp integrity_error({code, message, parameter, args}, _unknown),
    do: %DataIntegrity{code: code, message: message, parameter: parameter, args: args}

  defp integrity_error(nil, {code, message}),
    do: %DataIntegrity{code: code, message: message, parameter: nil, args: []}
end
