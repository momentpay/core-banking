defmodule ECBLoans.Loans.Modify do
  @moduledoc """
  Changing a loan application (`PUT /loans/{id}`), after Fineract's
  `LoanApplicationWritePlatformServiceJpaRepositoryImpl.modifyApplication`, `LoanApplicationValidator.validateForModify`
  and `LoanAssemblerImpl.updateFrom`.

  Only an application that is still pending approval can be changed. A request says what it changes and leaves
  out the rest, which stays as it was. What a request says is checked as an application would be, with the
  values it leaves out taken from the stored loan; the loan is then updated and its repayment schedule worked out
  again. The answer lists what changed: the value of each parameter that differs from the stored one, the
  locale (or date format) that went with it, and the charges (always an empty list, as loans carry no charges yet)
  as soon as the loan's terms changed or its repayment is monthly.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Submit, Transitions}
  alias ECBLoans.Schedule.Request
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformApiDataValidation}
  alias ECBPlatform.{Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Params.DatePattern

  # what a request can change, and the stored value it is compared with
  @numbers ~w(principal inArrearsTolerance interestRatePerPeriod)
  @integers ~w(repaymentEvery repaymentFrequencyType numberOfRepayments amortizationType
               interestRateFrequencyType interestType interestCalculationPeriodType
               graceOnPrincipalPayment graceOnInterestPayment graceOnInterestCharged)
  @dates ~w(submittedOnDate expectedDisbursementDate repaymentsStartingFromDate)
  @references ~w(clientId productId fundId loanOfficerId loanPurposeId)

  @doc "Changes application `id` as `p` says, for `user`."
  @spec modify!(struct, integer, Params.t()) :: Result.t()
  def modify!(user, id, %Params{} = p) do
    loan = Loans.fetch!(id)
    Params.check_supported!(p, Request.supported())
    check_pending!(loan)

    effective = effective(p, loan)
    check_amounts!(p)
    %{product: product, client: client, terms: terms} = assemble!(effective, p)
    refs = Submit.references!(effective)
    changes = changes(p, loan)

    update!(user, loan, p, %{
      effective: effective,
      product: product,
      client: client,
      terms: terms,
      refs: refs,
      changes: changes
    })
  end

  # an amount a request changes must make sense (a new application is checked against the product's limits instead)
  defp check_amounts!(p) do
    Validation.new("loan")
    |> amount(p, "principal", &Validation.positive_amount/1)
    |> amount(p, "inArrearsTolerance", &Validation.zero_or_positive_amount/1)
    |> Validation.raise_if_errors!()
  end

  defp amount(v, p, name, check) do
    if Params.exists?(p, name) do
      v |> Validation.param(name, Params.decimal_with_locale(p, name)) |> then(&check.(&1))
    else
      v
    end
  end

  # a request that changes nothing is refused, after whatever else is wrong with it
  defp assemble!(effective, p) do
    none? = Enum.all?(Map.keys(p.map), &(&1 in ~w(dateFormat locale loanType)))

    try do
      assembled = Request.assemble!(effective)
      if none?, do: raise(PlatformApiDataValidation, errors: [no_parameters()])
      assembled
    rescue
      error in PlatformApiDataValidation ->
        if none? and not Enum.any?(error.errors, &(&1.parameter == "id")),
          do: reraise(%{error | errors: error.errors ++ [no_parameters()]}, __STACKTRACE__),
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp no_parameters do
    %{
      code: "validation.msg.loan.no.parameters.for.update",
      developer_message: "No parameters passed for update.",
      default_message: "No parameters passed for update.",
      parameter: "id",
      args: []
    }
  end

  defp check_pending!(loan) do
    if loan.loan_status_id != Loans.status(:submitted) do
      raise DomainRuleViolation,
        code: "error.msg.loan.cannot.modify.loan.in.its.present.state",
        message:
          "Loan application with identifier #{loan.id} cannot be modified in its current state.",
        args: [loan.id]
    end
  end

  defp update!(user, loan, p, %{effective: effective, product: product, client: client} = given) do
    %{terms: terms, refs: refs, changes: changes} = given
    id = loan.id
    schedule = ECBLoans.Schedule.generate(terms)
    now = DateTime.utc_now()

    row =
      %{
        user: user,
        p: effective,
        product: product,
        client: client,
        terms: terms,
        schedule: schedule
      }
      |> Map.merge(%{refs: refs, external_id: nil, now: now})
      |> Submit.loan_row()
      |> Map.drop(
        ~w(account_no external_id created_by created_on_utc version loan_status_id loan_type_enum net_disbursal_amount)a
      )
      |> Map.merge(identity(p, loan))

    ECBPlatform.Integrity.translate(
      fn ->
        TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id), set: Map.to_list(row))
      end,
      %{},
      {"error.msg.unknown.data.integrity.issue", "Unknown data integrity issue with resource."}
    )

    Transitions.regenerate!(id, user)
    Loans.add_note(id, client.id, Params.string(p, "submittedOnNote"), user.id)
    external_id = Map.get(row, :external_id, loan.external_id)

    Result.new(
      office_id: client.office_id,
      client_id: client.id,
      loan_id: id,
      resource_id: id,
      resource_external_id: external_id,
      changes: changes
    )
  end

  # the account number and external id change only when the request gives them
  defp identity(p, loan) do
    %{}
    |> put_if(
      Params.exists?(p, "accountNo"),
      :account_no,
      blank_to_nil(Params.string(p, "accountNo")) || loan.account_no
    )
    |> put_if(
      Params.exists?(p, "externalId"),
      :external_id,
      blank_to_nil(Params.string(p, "externalId"))
    )
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: text)

  # --- the request with what it leaves out taken from the loan -------------------------------------------

  defp effective(%Params{map: map} = p, loan) do
    format = Params.date_format(p)
    dated? = format != nil and Params.string(p, "locale") != nil
    given_dates? = Enum.any?(@dates, &Map.has_key?(map, &1))

    stored =
      %{
        "principal" => number(loan.principal_amount),
        "inArrearsTolerance" => number(loan.arrearstolerance_amount),
        "interestRatePerPeriod" => number(loan.nominal_interest_rate_per_period),
        "repaymentEvery" => loan.repay_every,
        "repaymentFrequencyType" => loan.repayment_period_frequency_enum,
        "numberOfRepayments" => loan.number_of_repayments,
        "amortizationType" => loan.amortization_method_enum,
        "interestRateFrequencyType" => loan.interest_period_frequency_enum,
        "interestType" => loan.interest_method_enum,
        "interestCalculationPeriodType" => loan.interest_calculated_in_period_enum,
        "allowPartialPeriodInterestCalculation" => loan.allow_partial_period_interest_calcualtion,
        "loanTermFrequency" => loan.term_frequency,
        "loanTermFrequencyType" => loan.term_period_frequency_enum,
        "graceOnPrincipalPayment" => loan.grace_on_principal_periods,
        "graceOnInterestPayment" => loan.grace_on_interest_periods,
        "graceOnInterestCharged" => loan.grace_interest_free_periods,
        "graceOnArrearsAgeing" => loan.grace_on_arrears_ageing,
        "transactionProcessingStrategyCode" => loan.loan_transaction_strategy_code,
        "daysInYearType" => loan.days_in_year_enum,
        "clientId" => loan.client_id,
        "productId" => loan.product_id,
        "fundId" => loan.fund_id,
        "loanOfficerId" => loan.loan_officer_id,
        "loanPurposeId" => loan.loanpurpose_cv_id
      }
      |> Map.merge(
        if given_dates? and not dated? do
          %{}
        else
          pattern = format || "yyyy-MM-dd"

          %{
            "submittedOnDate" => date(loan.submittedon_date, pattern),
            "expectedDisbursementDate" => date(loan.expected_disbursedon_date, pattern),
            "repaymentsStartingFromDate" => date(loan.expected_firstrepaymenton_date, pattern)
          }
          |> Map.merge(if dated?, do: %{}, else: %{"dateFormat" => pattern, "locale" => "en"})
        end
      )
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %Params{p | map: Map.merge(stored, map)}
  end

  defp number(nil), do: nil

  defp number(d) do
    if Decimal.integer?(d), do: Decimal.to_integer(d), else: Decimal.to_float(d)
  end

  defp date(nil, _pattern), do: nil
  defp date(%Date{} = d, pattern), do: DatePattern.format(d, pattern)

  # --- what changed ---------------------------------------------------------------------------------------------

  defp changes(p, loan) do
    locale = Params.string(p, "locale")
    format = Params.date_format(p)

    stored = %{
      "principal" => loan.principal_amount,
      "inArrearsTolerance" => loan.arrearstolerance_amount,
      "interestRatePerPeriod" => loan.nominal_interest_rate_per_period,
      "repaymentEvery" => loan.repay_every,
      "repaymentFrequencyType" => loan.repayment_period_frequency_enum,
      "numberOfRepayments" => loan.number_of_repayments,
      "amortizationType" => loan.amortization_method_enum,
      "interestRateFrequencyType" => loan.interest_period_frequency_enum,
      "interestType" => loan.interest_method_enum,
      "interestCalculationPeriodType" => loan.interest_calculated_in_period_enum,
      "graceOnPrincipalPayment" => loan.grace_on_principal_periods,
      "graceOnInterestPayment" => loan.grace_on_interest_periods,
      "graceOnInterestCharged" => loan.grace_interest_free_periods
    }

    terms =
      for name <- @numbers ++ @integers,
          Params.exists?(p, name),
          changed?(p, name, stored[name]),
          into: %{} do
        {name, new_value(p, name)}
      end

    terms = if map_size(terms) > 0, do: Map.put(terms, "locale", locale), else: terms
    terms = if monthly?(p, loan), do: Map.put(terms, "locale", locale), else: terms
    terms = partial_period(terms, p, loan)

    terms
    |> Map.merge(references(p, loan))
    |> Map.merge(dates(p, loan, locale, format))
    |> Map.merge(frequency(p, loan))
    |> Map.merge(identifiers(p, loan))
    |> put_charges(terms)
  end

  # the charges are listed as soon as the loan's terms changed (and loans carry none)
  defp put_charges(changes, terms) do
    if map_size(terms) > 0 or Map.has_key?(changes, "charges"),
      do: Map.put(changes, "charges", []),
      else: changes
  end

  defp monthly?(p, loan) do
    frequency =
      if Params.exists?(p, "repaymentFrequencyType"),
        do: Params.integer_with_locale(p, "repaymentFrequencyType"),
        else: loan.repayment_period_frequency_enum

    frequency == 2
  end

  defp partial_period(terms, p, loan) do
    if Params.exists?(p, "allowPartialPeriodInterestCalculation") and
         Params.boolean(p, "allowPartialPeriodInterestCalculation") !=
           loan.allow_partial_period_interest_calcualtion,
       do:
         Map.put(
           terms,
           "allowPartialPeriodInterestCalculation",
           Params.boolean(p, "allowPartialPeriodInterestCalculation")
         ),
       else: terms
  end

  defp changed?(p, name, stored) when name in @numbers do
    case Params.decimal_with_locale(p, name) do
      nil -> stored != nil
      value -> stored == nil or Decimal.compare(value, stored) != :eq
    end
  end

  defp changed?(p, name, stored), do: Params.integer_with_locale(p, name) != stored

  defp new_value(p, name) when name in @numbers, do: Params.decimal_with_locale(p, name)
  defp new_value(p, name), do: Params.integer_with_locale(p, name)

  defp references(p, loan) do
    stored = %{
      "clientId" => loan.client_id,
      "productId" => loan.product_id,
      "fundId" => loan.fund_id,
      "loanOfficerId" => loan.loan_officer_id,
      "loanPurposeId" => loan.loanpurpose_cv_id
    }

    for name <- @references,
        Params.exists?(p, name),
        Json.long(p, name) != stored[name],
        into: %{} do
      {name, Json.long(p, name)}
    end
  end

  defp dates(p, loan, locale, format) do
    stored = %{
      "submittedOnDate" => loan.submittedon_date,
      "expectedDisbursementDate" => loan.expected_disbursedon_date,
      "repaymentsStartingFromDate" => loan.expected_firstrepaymenton_date
    }

    changed =
      for name <- @dates,
          Params.exists?(p, name),
          Params.date(p, name) != stored[name],
          into: %{} do
        {name, Params.string(p, name)}
      end

    if map_size(changed) > 0,
      do: Map.merge(changed, %{"dateFormat" => format, "locale" => locale}),
      else: changed
  end

  defp frequency(p, loan) do
    for {name, stored} <- [
          {"loanTermFrequency", loan.term_frequency},
          {"loanTermFrequencyType", loan.term_period_frequency_enum}
        ],
        Params.exists?(p, name),
        Params.integer_with_locale(p, name) != stored,
        into: %{} do
      {name, Params.integer_with_locale(p, name)}
    end
  end

  defp identifiers(p, loan) do
    Map.merge(
      changed_text(p, "accountNo", loan.account_no),
      changed_text(p, "externalId", loan.external_id)
    )
  end

  defp changed_text(p, name, stored) do
    if Params.exists?(p, name) and (Params.string(p, name) || "") != (stored || ""),
      do: %{name => Params.string(p, name) || ""},
      else: %{}
  end
end
