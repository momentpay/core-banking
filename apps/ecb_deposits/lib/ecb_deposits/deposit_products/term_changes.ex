defmodule ECBDeposits.DepositProducts.TermChanges do
  @moduledoc """
  What a request to change a deposit product changes in its pre-closure penalty, term and amounts, after Fineract's
  `DepositPreClosureDetail.update`, `DepositTermDetail.update` and `DepositProductAmountDetails.update`. A change is
  a parameter that is sent and differs from what the product has; the locale of the request is shown with the
  numbers that are read in it.
  """
  alias ECBDeposits.DepositEnums
  alias ECBPlatform.{Params, Validation}

  @integers [
    {"minDepositTerm", :min_deposit_term, :plain},
    {"maxDepositTerm", :max_deposit_term, :plain},
    {"minDepositTermTypeId", :min_deposit_term_type_enum, :unit},
    {"maxDepositTermTypeId", :max_deposit_term_type_enum, :unit},
    {"inMultiplesOfDepositTerm", :in_multiples_of_deposit_term, :plain},
    {"inMultiplesOfDepositTermTypeId", :in_multiples_of_deposit_term_type_enum, :unit}
  ]

  @amounts [
    {"minDepositAmount", :min_deposit_amount},
    {"maxDepositAmount", :max_deposit_amount},
    {"depositAmount", :deposit_amount}
  ]

  @doc """
  The changes a request makes to a product's `term` (the row as stored): answers the changes to show, the term as
  it is now and the problems of `v` with a minimum term above the maximum added.
  """
  @spec change(Params.t(), map, Validation.t()) :: {map, map, Validation.t()}
  def change(%Params{} = p, term, %Validation{} = v) do
    state =
      %{changes: %{}, term: term, locale: Params.locale(p) || ""}
      |> applicable(p)
      |> penalty(p)
      |> integers(p)
      |> amounts(p)

    {state.changes, state.term, minimum_check(v, state.term)}
  end

  @doc "A term in days: months count 30 and years 365 (what Fineract compares terms by)."
  @spec days(integer, integer | nil) :: integer
  def days(count, 0), do: count
  def days(count, 1), do: count * 7
  def days(count, 2), do: count * 30
  def days(count, 3), do: count * 365
  def days(_count, _type), do: 0

  defp applicable(state, p) do
    if Params.exists?(p, "preClosurePenalApplicable") do
      new = Params.boolean(p, "preClosurePenalApplicable") == true
      record(state, "preClosurePenalApplicable", :pre_closure_penal_applicable, new, new, false)
    else
      state
    end
  end

  # a penalty that is not applicable has no rate and no basis
  defp penalty(%{term: %{pre_closure_penal_applicable: true}} = state, p),
    do: state |> penalty_interest(p) |> penalty_basis(p)

  defp penalty(state, _p),
    do: %{
      state
      | term: %{
          state.term
          | pre_closure_penal_interest: nil,
            pre_closure_penal_interest_on_enum: nil
        }
    }

  defp penalty_interest(state, p) do
    if Params.exists?(p, "preClosurePenalInterest") do
      new = Params.decimal_with_locale(p, "preClosurePenalInterest")
      record(state, "preClosurePenalInterest", :pre_closure_penal_interest, new, new, true)
    else
      state
    end
  end

  defp penalty_basis(state, p) do
    if Params.exists?(p, "preClosurePenalInterestOnTypeId") do
      new = Params.integer(p, "preClosurePenalInterestOnTypeId")
      shown = DepositEnums.pre_closure_on(new)

      record(
        state,
        "preClosurePenalInterestOnTypeId",
        :pre_closure_penal_interest_on_enum,
        new,
        shown,
        true
      )
    else
      state
    end
  end

  defp integers(state, p), do: Enum.reduce(@integers, state, &integer(&2, p, &1))

  defp integer(state, p, {key, column, kind}) do
    if Params.exists?(p, key) do
      new = Params.integer(p, key)
      shown = if kind == :unit, do: DepositEnums.term_unit(new), else: new
      record(state, key, column, new, shown, false)
    else
      state
    end
  end

  defp amounts(state, p), do: Enum.reduce(@amounts, state, &amount(&2, p, &1))

  defp amount(state, p, {key, column}) do
    if Params.exists?(p, key) do
      new = Params.decimal_with_locale(p, key)
      record(state, key, column, new, new, true)
    else
      state
    end
  end

  defp record(state, key, column, new, shown, locale?) do
    if differs?(Map.fetch!(state.term, column), new) do
      changes = Map.put(state.changes, key, shown)
      changes = if locale?, do: Map.put(changes, "locale", state.locale), else: changes
      %{state | changes: changes, term: Map.put(state.term, column, new)}
    else
      state
    end
  end

  defp differs?(nil, nil), do: false
  defp differs?(nil, _), do: true
  defp differs?(_, nil), do: true
  defp differs?(%Decimal{} = a, %Decimal{} = b), do: not Decimal.eq?(a, b)
  defp differs?(a, b), do: a != b

  # a minimum term above the maximum is refused with the minimum's own problem
  defp minimum_check(v, term) do
    if term.min_deposit_term && term.max_deposit_term &&
         days(term.min_deposit_term, term.min_deposit_term_type_enum) >
           days(term.max_deposit_term, term.max_deposit_term_type_enum) do
      v
      |> Validation.param("minDepositTerm", term.min_deposit_term)
      |> Validation.fail_with_code(".greater.than.maxDepositTerm", [
        term.min_deposit_term,
        term.max_deposit_term
      ])
    else
      v
    end
  end
end
