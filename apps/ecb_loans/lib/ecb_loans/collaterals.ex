defmodule ECBLoans.Collaterals do
  @moduledoc """
  The collateral offered for a loan (`m_loan_collateral`), following Fineract's `CollateralsApiResource` and its
  services. A collateral has a type (a value of the code `LoanCollateral`), and may be added, changed or removed only
  while the loan awaits approval.

  Fineract's endpoints bind their body to classes that carry less than the command reads, and E-CoreBank keeps what
  that does: a collateral is created from its `collateralTypeId` alone (its `value` and `description` are not kept),
  and is changed only in its `description`. Any other parameter is ignored.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBParty.Lookups
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, InvalidNumber, ResourceNotFound}
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @pending 100
  @code "LoanCollateral"

  # --- reads --------------------------------------------------------------------------------------

  @select """
  SELECT lc.id, lc.loan_id, lc.description, lc.value, cv.id AS type_id, cv.code_value AS type_name
  FROM m_loan_collateral lc
  JOIN m_code_value cv ON cv.id = lc.type_cv_id
  """

  @doc "The collaterals of a loan, oldest first."
  @spec list(integer) :: [map]
  def list(loan_id), do: query("WHERE lc.loan_id = $1 ORDER BY lc.id", [loan_id])

  @doc "One collateral of a loan, or `nil`."
  @spec get(integer, integer) :: map | nil
  def get(loan_id, id),
    do: query("WHERE lc.loan_id = $1 AND lc.id = $2", [loan_id, id]) |> List.first()

  defp query(tail, params) do
    %{columns: columns, rows: rows} = TenantRepo.query!(@select <> tail, params)
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
  end

  @doc "The error for a collateral that is not there for the loan."
  @spec not_found(integer, integer) :: Exception.t()
  def not_found(loan_id, id) do
    ResourceNotFound.new(
      "error.msg.loan.collateral.",
      "Collateral with Id #{id} does not exist for loan with Id #{loan_id}",
      [loan_id, id]
    )
  end

  # --- writes -------------------------------------------------------------------------------------

  @doc "Adds a collateral of the type `collateralTypeId` to loan `loan_id`."
  @spec create!(struct, integer, Params.t()) :: Result.t()
  def create!(_user, loan_id, %Params{} = p) do
    type_id = type_id(p)

    Validation.new("collateral")
    |> Validation.param("collateralTypeId", type_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(loan_id)
    Lookups.code_value!(@code, type_id)
    check_pending!(loan, "created", [loan.id])

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_loan_collateral",
        [%{loan_id: loan.id, type_cv_id: type_id}],
        returning: [:id]
      )

    Result.new(loan_id: loan.id, resource_id: id)
  end

  @doc "Changes the description of a collateral."
  @spec update!(struct, integer, integer, Params.t()) :: Result.t()
  def update!(_user, loan_id, id, %Params{} = p) do
    description = Params.string(p, "description")

    Validation.new("collateral")
    |> Validation.param("description", description)
    |> Validation.ignore_if_null()
    |> Validation.max_length(500)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(loan_id)

    # Fineract looks the collateral up by its id alone
    collateral =
      TenantRepo.one(
        from(c in "m_loan_collateral", where: c.id == ^id, select: %{description: c.description})
      ) || raise not_found(loan_id, id)

    changes =
      if description != nil and description != collateral.description,
        do: %{"description" => description},
        else: %{}

    check_pending!(loan, "updated", [loan.id])

    if changes != %{} do
      TenantRepo.update_all(from(c in "m_loan_collateral", where: c.id == ^id),
        set: [description: if(description == "", do: nil, else: description)]
      )
    end

    Result.new(loan_id: loan.id, resource_id: id, changes: if(changes != %{}, do: changes))
  end

  @doc "Removes a collateral."
  @spec delete!(struct, integer, integer) :: Result.t()
  def delete!(_user, loan_id, id) do
    loan = Loans.fetch!(loan_id)
    get(loan_id, id) || raise not_found(loan_id, id)
    check_pending!(loan, "deleted", [loan.id, id])
    TenantRepo.delete_all(from(c in "m_loan_collateral", where: c.id == ^id))
    Result.new(loan_id: loan.id, resource_id: id)
  end

  defp check_pending!(%{loan_status_id: @pending}, _what, _args), do: :ok

  defp check_pending!(_loan, what, args) do
    raise DomainRuleViolation,
      code:
        "error.msg.loan.collateral.associated.loan.not.in.submitted.and.pending.approval.stage",
      message:
        "This collateral cannot be #{what} as the loan it is associated with is not in submitted and pending approval stage",
      args: args
  end

  # the type is a number; text that is not one is Fineract's un-enveloped message
  defp type_id(%Params{} = p) do
    case Params.value(p, "collateralTypeId") do
      nil ->
        nil

      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, ""} -> n
          _ -> raise InvalidNumber, parameter: "collateralTypeId", value: value
        end

      value ->
        raise InvalidNumber, parameter: "collateralTypeId", value: to_string(value)
    end
  end
end
