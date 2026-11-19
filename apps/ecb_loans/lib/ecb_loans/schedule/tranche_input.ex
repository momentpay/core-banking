defmodule ECBLoans.Schedule.TrancheInput do
  @moduledoc """
  The `disbursementData` of a loan application: the tranches a loan on a product that allows several
  disbursements is paid out in, each with the date it is expected and its principal.

  Checked as Fineract's `LoanApplicationValidator` does (`validateLoanMultiDisbursementDate`: the dates in order,
  the first on the expected disbursement date, none before it, every amount given, the sum within the loan's
  principal; `validateDisbursementDetails`: what the product requires or forbids and how many tranches it
  allows). A product that does not allow tranches ignores what the request says about them, as Fineract does.
  """
  alias ECBPlatform.Errors.{DomainRuleViolation, ServerError}
  alias ECBPlatform.{Params, Validation}

  @doc "Whether the product pays out in tranches."
  @spec multi?(map) :: boolean
  def multi?(product), do: product.multi_disburse == true

  @doc """
  The tranches the request names, as `%{date:, principal:}` (either may be `nil`), in the order given. A body that
  is not a list of objects answers Fineract's plain server error.
  """
  @spec entries(Params.t()) :: [map]
  def entries(%Params{} = p) do
    case Params.value(p, "disbursementData") do
      list when is_list(list) ->
        Enum.map(list, fn
          entry when is_map(entry) -> entry(sub(p, entry))
          _ -> raise ServerError
        end)

      _ ->
        []
    end
  end

  defp sub(%Params{map: map} = p, entry) do
    shared = Map.take(map, ["locale", "dateFormat"])
    %Params{p | map: Map.merge(entry, shared)}
  end

  defp entry(entry) do
    %{
      id: ECBPlatform.Json.long(entry, "id"),
      date: Params.date(entry, "expectedDisbursementDate"),
      principal: principal(entry)
    }
  end

  # an amount that cannot be read is a plain server error in Fineract, not a validation problem
  defp principal(entry) do
    Params.decimal_with_locale(entry, "principal")
  rescue
    _ in ECBPlatform.Errors.PlatformApiDataValidation -> reraise ServerError, __STACKTRACE__
  end

  @doc """
  What the product requires of the request (`validateDisbursementDetails`): refused outright, before the other
  problems of the request are reported.
  """
  @spec details!(Params.t(), map) :: :ok
  def details!(%Params{} = p, product) do
    if multi?(product) do
      required!(p, product)
      max!(length(entries(p)), product)
    else
      :ok
    end
  end

  @doc "Refuses tranches for a product that allows none, and none for a product that needs them."
  @spec required!(Params.t(), map) :: :ok
  def required!(%Params{} = p, product) do
    count = length(entries(p))

    cond do
      product.disallow_expected_disbursements and count > 0 ->
        refuse!(
          "error.msg.disbursementData.not.allowed",
          "For this loan product, disbursement details are not allowed",
          []
        )

      not product.disallow_expected_disbursements and count == 0 ->
        refuse!(
          "error.msg.disbursementData.required",
          "For this loan product, disbursement details must be provided",
          []
        )

      true ->
        :ok
    end
  end

  @doc "Refuses more tranches than the product allows."
  @spec max!(non_neg_integer, map) :: :ok
  def max!(count, product) do
    if count > (product.max_tranche_count || 0) do
      refuse!(
        "error.msg.disbursementData.exceeding.max.tranche.count",
        "Number of tranche shouldn't be greater than #{product.max_tranche_count}",
        [product.max_tranche_count, count]
      )
    else
      :ok
    end
  end

  @doc "Equal amortization cannot be paid out in tranches (Fineract's own refusal)."
  @spec equal_amortization!() :: no_return
  def equal_amortization! do
    refuse!(
      "error.msg.equal.amortization.does.not.support.tranche.disbursal",
      "Equal Amortization does not support tranche disbursal",
      ["tranche disbursal"]
    )
  end

  defp refuse!(code, message, args),
    do: raise(DomainRuleViolation, code: code, message: message, args: args)

  @doc """
  The checks of `validateLoanMultiDisbursementDate`, added to `v` (a `Validation`): `expected` is the loan's
  expected disbursement date and `principal` what the loan is for.
  """
  @spec validate(Validation.t(), Params.t(), Date.t() | nil, Decimal.t() | nil) :: Validation.t()
  def validate(%Validation{} = v, %Params{} = p, expected, principal) do
    if Params.exists?(p, "disbursementData"),
      do: check_entries(v, p, entries(p), expected, principal),
      else: v
  end

  defp check_entries(v, p, entries, expected, principal) do
    v = ordered(v, entries)

    if expected != nil and principal != nil and entries != [] do
      if Params.boolean(p, "isEqualAmortization") == true, do: equal_amortization!()
      v = entries |> Enum.with_index() |> Enum.reduce(v, &entry_errors(&1, &2, expected))
      sum(v, entries, principal)
    else
      v
    end
  end

  # one problem for each pair of tranches that are out of order
  defp ordered(v, entries) do
    dated = for %{date: date} <- entries, date != nil, do: date

    pairs =
      for {a, i} <- Enum.with_index(dated),
          {b, j} <- Enum.with_index(dated),
          j > i,
          Date.compare(a, b) == :gt,
          do: :out_of_order

    Enum.reduce(pairs, v, fn _, v ->
      v
      |> Validation.param("disbursementData", nil)
      |> Validation.fail_with_code(
        "disbursements.should.be.ordered.based.on.their.disbursement.dates"
      )
    end)
  end

  defp entry_errors({entry, index}, v, expected) do
    v
    |> date_errors(entry.date, index, expected)
    |> principal_errors(entry.principal, index)
  end

  defp date_errors(v, nil, index, _expected),
    do: mandatory(v, "expectedDisbursementDate", index)

  defp date_errors(v, date, 0, expected) do
    if date == expected,
      do: v,
      else:
        v
        |> Validation.param("expectedDisbursementDate", nil)
        |> Validation.fail_with_code(
          "first.disbursement.date.must.start.with.expected.disbursement.date"
        )
  end

  defp date_errors(v, date, _index, expected) do
    if Date.compare(date, expected) == :lt,
      do:
        v
        |> Validation.param("disbursementData", nil)
        |> Validation.fail_with_code(
          "disbursement.date.of.tranche.cannot.be.before.expected.disbursement.date"
        ),
      else: v
  end

  defp principal_errors(v, nil, index), do: mandatory(v, "principal", index)
  defp principal_errors(v, _principal, _index), do: v

  defp mandatory(v, name, index) do
    parameter = "disbursementData[#{index}][#{name}]"

    Validation.add_error(
      v,
      "validation.msg.loan.disbursementData.#{name}.cannot.be.blank",
      "The parameter `#{parameter}` is mandatory.",
      parameter,
      [index]
    )
  end

  defp sum(v, entries, principal) do
    total =
      for %{principal: amount} <- entries, amount != nil, reduce: Decimal.new(0) do
        total -> Decimal.add(total, amount)
      end

    if Decimal.gt?(total, principal),
      do:
        v
        |> Validation.param("principal", nil)
        |> Validation.fail_with_code(
          "sum.of.multi.disburse.amounts.must.be.equal.to.or.lesser.than.approved.principal"
        ),
      else: v
  end

  @doc """
  The tranches a schedule is worked out from, as `%{date:, amount:}` (`ECBMoney`), in the order given; none for a
  product that does not pay out in tranches. Amounts that are not above zero are refused: Fineract's answer for
  them is not a schedule worth copying.
  """
  @spec terms(Params.t(), map, ECBMoney.Currency.t(), ECBMoney.Context.t()) :: [map]
  def terms(%Params{} = p, product, currency, context) do
    if multi?(product),
      do: for(entry <- entries(p), do: tranche(entry, currency, context)),
      else: []
  end

  defp tranche(%{date: date, principal: amount}, currency, context) do
    if not Decimal.gt?(amount, 0), do: unsupported!("a tranche that is not above zero")
    %{date: date, amount: ECBMoney.new(currency, amount, context)}
  end

  @doc "Refuses what is not built yet."
  @spec unsupported!(String.t()) :: no_return
  def unsupported!(what) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message: "These loan application settings are not supported yet by E-CoreBank: " <> what,
      args: [what]
  end
end
