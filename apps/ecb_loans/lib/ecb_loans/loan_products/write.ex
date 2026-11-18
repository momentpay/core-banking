defmodule ECBLoans.LoanProducts.Write do
  @moduledoc """
  Creating and changing loan products, following Fineract's
  `LoanProductWritePlatformServiceJpaRepositoryImpl`, `LoanProductAssembler` and the `LoanProduct` entity,
  for the core of a loan product (see `ECBLoans.LoanProducts`).

  A product's charges must be in the product's currency; its fund must exist; its transaction-processing
  strategy must be one that is known. The yearly interest rate is worked out from the rate per period.
  """
  import Ecto.Query

  alias ECBLoans.{Apr, LoanProducts}
  alias ECBLoans.LoanProducts.{Accounting, Validate}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Integrity, Json, Params, TenantRepo}

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the loan product `params` describe, with its charges and account mappings."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = p) do
    Validate.create!(p)
    dates!(p)

    fund = fund!(Json.long(p, "fundId"))
    currency_code = Params.string(p, "currencyCode")
    charge_ids = charges!(p, currency_code)
    rule = Params.integer_in_default_locale(p, "accountingRule")
    code = Params.string(p, "transactionProcessingStrategyCode")

    row =
      p
      |> new_row(currency_code, rule)
      |> Map.merge(%{
        fund_id: fund,
        loan_transaction_strategy_code: code,
        loan_transaction_strategy_name: LoanProducts.strategy_name(code)
      })

    id = insert!(p, row)
    guard(%{}, fn -> LoanProducts.set_charges!(id, charge_ids) end)
    Accounting.create!(id, p, rule)
    Result.new(resource_id: id)
  end

  defp new_row(p, currency_code, rule) do
    repayments = Params.integer_with_locale(p, "numberOfRepayments")
    every = Params.integer_with_locale(p, "repaymentEvery")
    frequency = Params.integer_in_default_locale(p, "repaymentFrequencyType")
    interest_frequency = Params.integer_in_default_locale(p, "interestRateFrequencyType")
    rate = Params.decimal_with_locale(p, "interestRatePerPeriod")
    days_in_year = Params.integer_in_default_locale(p, "daysInYearType")
    multi = Validate.multi?(p)

    %{
      name: Params.command_string(p, "name"),
      short_name: Params.command_string(p, "shortName"),
      description: Params.string(p, "description"),
      external_id: Params.string(p, "externalId"),
      start_date: Params.date(p, "startDate"),
      close_date: Params.date(p, "closeDate"),
      currency_code: currency_code,
      currency_digits: Params.integer_in_default_locale(p, "digitsAfterDecimal"),
      currency_multiplesof: Params.integer_in_default_locale(p, "inMultiplesOf"),
      principal_amount: Params.decimal_with_locale(p, "principal"),
      min_principal_amount: Params.decimal_with_locale(p, "minPrincipal"),
      max_principal_amount: Params.decimal_with_locale(p, "maxPrincipal"),
      number_of_repayments: repayments,
      min_number_of_repayments: Params.integer_with_locale(p, "minNumberOfRepayments"),
      max_number_of_repayments: Params.integer_with_locale(p, "maxNumberOfRepayments"),
      repay_every: every,
      repayment_period_frequency_enum: frequency,
      nominal_interest_rate_per_period: rate,
      min_nominal_interest_rate_per_period:
        Params.decimal_with_locale(p, "minInterestRatePerPeriod"),
      max_nominal_interest_rate_per_period:
        Params.decimal_with_locale(p, "maxInterestRatePerPeriod"),
      interest_period_frequency_enum: interest_frequency,
      annual_nominal_interest_rate:
        Apr.calculate(interest_frequency, rate, repayments, every, frequency, days_in_year),
      amortization_method_enum: Params.integer_in_default_locale(p, "amortizationType"),
      interest_method_enum: Params.integer_in_default_locale(p, "interestType"),
      interest_calculated_in_period_enum:
        Params.integer_in_default_locale(p, "interestCalculationPeriodType"),
      allow_partial_period_interest_calcualtion: flag(p, "allowPartialPeriodInterestCalculation"),
      arrearstolerance_amount: Params.decimal_with_locale(p, "inArrearsTolerance"),
      grace_on_principal_periods: Params.integer_with_locale(p, "graceOnPrincipalPayment"),
      grace_on_interest_periods: Params.integer_with_locale(p, "graceOnInterestPayment"),
      grace_interest_free_periods: Params.integer_with_locale(p, "graceOnInterestCharged"),
      grace_on_arrears_ageing: Params.integer_with_locale(p, "graceOnArrearsAgeing"),
      overdue_days_for_npa: Params.integer_with_locale(p, "overdueDaysForNPA"),
      days_in_month_enum: Params.integer_in_default_locale(p, "daysInMonthType"),
      days_in_year_enum: days_in_year,
      min_days_between_disbursal_and_first_repayment:
        Json.long(p, "minimumDaysBetweenDisbursalAndFirstRepayment"),
      can_define_fixed_emi_amount: flag(p, "canDefineInstallmentAmount"),
      installment_amount_in_multiples_of:
        Params.integer_with_locale(p, "installmentAmountInMultiplesOf"),
      accounting_type: rule,
      include_in_borrower_cycle: flag(p, "includeInBorrowerCycle"),
      can_use_for_topup: flag(p, "canUseForTopup"),
      enable_accrual_activity_posting: flag(p, "enableAccrualActivityPosting"),
      principal_threshold_for_last_installment:
        Params.decimal_with_locale(p, "principalThresholdForLastInstallment") ||
          Decimal.new(if(multi, do: 50, else: 0)),
      allow_multiple_disbursals: multi,
      max_disbursals: if(multi, do: Params.integer_in_default_locale(p, "maxTrancheCount")),
      max_outstanding_loan_balance:
        if(multi, do: Params.decimal_with_locale(p, "outstandingLoanBalance")),
      disallow_expected_disbursements: flag(p, "disallowExpectedDisbursements"),
      account_moves_out_of_npa_only_on_arrears_completion:
        flag(p, "accountMovesOutOfNPAOnlyOnArrearsCompletion"),
      sync_expected_with_disbursement_date: flag(p, "syncExpectedWithDisbursementDate"),
      due_days_for_repayment_event: Params.integer_with_locale(p, "dueDaysForRepaymentEvent"),
      overdue_days_for_repayment_event:
        Params.integer_with_locale(p, "overDueDaysForRepaymentEvent"),
      repayment_start_date_type_enum:
        Params.integer_in_default_locale(p, "repaymentStartDateType") || 1,
      hold_guarantee_funds: false
    }
  end

  # a product cannot close before it starts (a close date alone is accepted)
  defp dates!(p) do
    start = Params.date(p, "startDate")
    close = Params.date(p, "closeDate")

    if start != nil and close != nil and Date.compare(close, start) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.product.close.date.cannot.be.before.start.date.close.date",
        message: "Loan product close date cannot be before the start date",
        args: [Date.to_iso8601(start), Date.to_iso8601(close)]
    end
  end

  defp flag(p, key), do: Params.boolean(p, key) == true

  # --- fund and charges ---------------------------------------------------------------------------

  defp fund!(nil), do: nil

  defp fund!(id) do
    if TenantRepo.exists?(from(f in "m_fund", where: f.id == ^id)) do
      id
    else
      raise ResourceNotFound,
        code: "error.msg.fund.id.invalid",
        message: "Fund with identifier #{id} does not exist",
        args: [id]
    end
  end

  # the charges named in the request (by `id`), as ids; each must exist, be active and be in the product's currency
  defp charges!(p, currency_code) do
    case Params.value(p, "charges") do
      list when is_list(list) ->
        for %{"id" => raw} <- list,
            do: charge!(Json.long(%Params{map: %{"id" => raw}}, "id"), currency_code)

      _ ->
        []
    end
  end

  defp charge!(id, currency_code) do
    row =
      TenantRepo.one(
        from(c in "m_charge",
          where: c.id == ^id,
          select: %{
            name: c.name,
            currency: c.currency_code,
            deleted: c.is_deleted,
            active: c.is_active
          }
        )
      )

    cond do
      row == nil or row.deleted ->
        raise ResourceNotFound,
          code: "error.msg.charge.id.invalid",
          message: "Charge with identifier #{id} does not exist",
          args: [id]

      not row.active ->
        raise DomainRuleViolation,
          code: "error.msg.charge.is.not.active",
          message: "Charge '#{row.name}' with identifier #{id} is not active",
          args: [row.name, id]

      row.currency != currency_code ->
        raise DomainRuleViolation,
          code: "error.msg.charge.attach.to.loan.product.invalid.currency",
          message: "Charge and Loan Product must have the same currency.",
          args: []

      true ->
        id
    end
  end

  # --- storing ----------------------------------------------------------------------------------

  defp insert!(_p, row) do
    {1, [%{id: id}]} =
      guard(row, fn -> TenantRepo.insert_all("m_product_loan", [row], returning: [:id]) end)

    id
  end

  # Fineract looks for constraint names in the database's message. Only the short name's is the one PostgreSQL
  # uses too, so a duplicate name, external id or charge is an unknown data-integrity problem there as well.
  defp guard(row, fun) do
    Integrity.translate(
      fn ->
        short_name_free!(row)
        fun.()
      end,
      %{
        "m_product_loan_short_name_key" =>
          {"error.msg.product.loan.duplicate.short.name",
           "Loan product with short name `#{row[:short_name]}` already exists", "shortName",
           [row[:short_name]]}
      },
      {"error.msg.product.loan.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end

  # When both the name and the short name are taken, Fineract's database reports the short name first. Its
  # failed insert has used up an id, so this does too.
  defp short_name_free!(%{short_name: short_name} = row) do
    if TenantRepo.exists?(from(lp in "m_product_loan", where: lp.short_name == ^short_name)) do
      TenantRepo.query!("SELECT nextval(pg_get_serial_sequence('m_product_loan', 'id'))")

      raise ECBPlatform.Errors.DataIntegrity,
        code: "error.msg.product.loan.duplicate.short.name",
        message: "Loan product with short name `#{short_name}` already exists",
        parameter: "shortName",
        args: [row.short_name]
    end
  end

  defp short_name_free!(_), do: :ok

  # --- update ----------------------------------------------------------------------

  @doc "Changes loan product `id` (not built yet)."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{}) do
    _ = LoanProducts.fetch!(id)

    raise DomainRuleViolation,
      code: "error.msg.loanproduct.feature.not.supported.yet",
      message: "Changing a loan product is not supported yet by E-CoreBank.",
      args: []
  end
end
