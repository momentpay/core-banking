defmodule ECBLoans.Loans.Submit do
  @moduledoc """
  Submitting a loan application, following Fineract's `LoanApplicationWritePlatformServiceJpaRepositoryImpl.submitApplication`
  and `LoanAssemblerImpl.assembleFrom`.

  The request is checked and turned into terms by `ECBLoans.Schedule.Request`, the repayment schedule is
  worked out from them, and the loan, its schedule and an optional note are stored. The loan starts
  "submitted and pending approval" with the number of repayments, the amounts and the dates the request
  asked for (or the product supplied). A fund, loan officer or loan purpose the request names must exist.
  """
  import Ecto.Query

  alias ECBLoans.{Loans, Schedule}
  alias ECBLoans.Schedule.Request
  alias ECBOrg.{Funds, Staff}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Json, Params, TenantRepo}

  @doc "Submits the application `p` describes for `user`; the result carries the new loan's id."
  @spec create!(struct, Params.t()) :: Result.t()
  def create!(user, %Params{} = p) do
    %{product: product, client: client, terms: terms} = Request.assemble!(p)
    refs = references!(p)
    check_first_repayment_date!(terms)
    external_id = Params.string(p, "externalId") |> blank_to_nil()
    if external_id, do: external_id_free!(external_id)

    schedule = Schedule.generate(terms)
    now = DateTime.utc_now()

    id =
      insert!(
        loan_row(%{
          user: user,
          p: p,
          product: product,
          client: client,
          terms: terms,
          schedule: schedule,
          refs: refs,
          external_id: external_id,
          now: now
        }),
        Params.string(p, "accountNo")
      )

    generate_account_no!(id, p, product, client)
    insert_installments!(id, schedule, user, now)
    Loans.add_note(id, client.id, Params.string(p, "submittedOnNote"), user.id)

    Result.new(
      office_id: client.office_id,
      client_id: client.id,
      loan_id: id,
      resource_id: id,
      resource_external_id: external_id
    )
  end

  # the fund, officer and purpose are looked up in this order
  @doc false
  def references!(p) do
    fund = Json.long(p, "fundId") |> fund!()
    officer = Json.long(p, "loanOfficerId") |> officer!()
    purpose = Json.long(p, "loanPurposeId") |> purpose!()
    %{fund: fund, officer: officer, purpose: purpose}
  end

  defp fund!(nil), do: nil
  defp fund!(id), do: Funds.fetch!(id)

  defp officer!(nil), do: nil

  defp officer!(id) do
    staff = Staff.fetch!(id)

    unless staff.is_loan_officer do
      raise ResourceNotFound,
        code: "error.msg.staff.id.invalid.role",
        message: "Staff with identifier #{id} is not a loan_officer",
        args: [id]
    end

    staff
  end

  defp purpose!(nil), do: nil

  defp purpose!(id) do
    row =
      TenantRepo.one(from(v in "m_code_value", where: v.id == ^id, select: %{id: v.id}))

    row ||
      raise ResourceNotFound,
        code: "error.msg.codevalue.id.invalid",
        message: "Code value with identifier #{id} does not exist",
        args: [id]
  end

  defp check_first_repayment_date!(%{first_repayment_date: first, submitted_date: submitted})
       when not is_nil(first) do
    if Date.compare(submitted, first) == :gt do
      raise DomainRuleViolation,
        code:
          "error.msg.loan.application.submitted.on.date.cannot.be.after.the.loan.expected.first.repayment.date",
        message: "submittedOnDate cannot be after the loans  expectedFirstRepaymentOnDate.",
        args: [Date.to_iso8601(submitted), Date.to_iso8601(first)]
    end
  end

  defp check_first_repayment_date!(_terms), do: :ok

  defp external_id_free!(external_id) do
    if TenantRepo.exists?(from(l in "m_loan", where: l.external_id == ^external_id)) do
      raise ECBPlatform.Errors.DomainRuleViolation,
        code: "error.msg.loan.with.externalId.already.used",
        message: "Loan with externalId is already registered.",
        args: []
    end
  end

  # --- the loan row ---------------------------------------------------------------------------

  @doc false
  def loan_row(%{
        user: user,
        p: p,
        product: product,
        client: client,
        terms: terms,
        schedule: schedule,
        refs: refs,
        external_id: external_id,
        now: now
      }) do
    principal = ECBMoney.amount(terms.principal)
    last = List.last(schedule.periods)

    %{
      account_no: temporary_account_no(),
      external_id: external_id,
      client_id: client.id,
      product_id: product.id,
      fund_id: refs.fund && refs.fund.id,
      loan_officer_id: refs.officer && refs.officer.id,
      loanpurpose_cv_id: refs.purpose && refs.purpose.id,
      loan_status_id: Loans.status(:submitted),
      loan_type_enum: 1,
      currency_code: product.currency.code,
      currency_digits: product.currency.decimal_places,
      currency_multiplesof: product.currency.multiples_of,
      principal_amount_proposed: principal,
      principal_amount: principal,
      approved_principal: principal,
      net_disbursal_amount: principal,
      arrearstolerance_amount:
        Params.decimal_with_locale(p, "inArrearsTolerance") || product.in_arrears_tolerance,
      nominal_interest_rate_per_period: Params.decimal_with_locale(p, "interestRatePerPeriod"),
      interest_period_frequency_enum: rate_frequency(p, product),
      annual_nominal_interest_rate: terms.annual_rate,
      interest_method_enum: terms.interest_method,
      interest_calculated_in_period_enum: terms.interest_calculation_period,
      allow_partial_period_interest_calcualtion: terms.allow_partial_period == true,
      term_frequency: terms.loan_term_frequency,
      term_period_frequency_enum: Params.integer_with_locale(p, "loanTermFrequencyType"),
      repay_every: terms.repayment_every,
      repayment_period_frequency_enum: terms.repayment_frequency,
      number_of_repayments: terms.number_of_repayments,
      grace_on_principal_periods:
        given_or(p, "graceOnPrincipalPayment", product.grace_on_principal),
      grace_on_interest_periods: given_or(p, "graceOnInterestPayment", product.grace_on_interest),
      grace_interest_free_periods:
        given_or(p, "graceOnInterestCharged", product.grace_on_interest_charged),
      grace_on_arrears_ageing:
        given_or(p, "graceOnArrearsAgeing", product.grace_on_arrears_ageing),
      amortization_method_enum: terms.amortization,
      submittedon_date: terms.submitted_date,
      expected_disbursedon_date: terms.disbursement_date,
      expected_firstrepaymenton_date: Params.date(p, "repaymentsStartingFromDate"),
      expected_maturedon_date: last.due,
      maturedon_date: last.due,
      loan_transaction_strategy_code: strategy_code(p, product),
      loan_transaction_strategy_name:
        ECBLoans.LoanProducts.strategy_name(strategy_code(p, product)),
      days_in_month_enum: terms.days_in_month,
      days_in_year_enum: terms.days_in_year,
      interest_recalculation_enabled: false,
      repayment_start_date_type_enum: product.repayment_start_id || 1,
      is_npa: false,
      version: 1,
      is_topup: false,
      is_equal_amortization: false,
      is_fraud: false,
      is_charged_off: false,
      enable_down_payment: false,
      enable_installment_level_delinquency: false,
      enable_accrual_activity_posting: product.enable_accrual_activity_posting == true,
      enable_income_capitalization: false,
      enable_buy_down_fee: false,
      allow_full_term_for_tranche: false,
      enable_auto_repayment_for_down_payment: false,
      loan_schedule_type: "CUMULATIVE",
      loan_schedule_processing_type: "HORIZONTAL",
      charge_off_behaviour: "REGULAR",
      interest_recognition_on_disbursement_date: false,
      is_merchant_buy_down_fee: false,
      created_on_utc: now,
      created_by: user.id,
      last_modified_by: user.id,
      last_modified_on_utc: now
    }
  end

  defp rate_frequency(p, product) do
    if Params.exists?(p, "interestRateFrequencyType"),
      do: Params.integer_with_locale(p, "interestRateFrequencyType"),
      else: product.interest_frequency_id
  end

  defp strategy_code(p, product),
    do: Params.string(p, "transactionProcessingStrategyCode") || product.strategy_code

  defp given_or(p, name, fallback), do: Params.integer_with_locale(p, name) || fallback

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp insert!(row, supplied_account_no) do
    row =
      case blank_to_nil(supplied_account_no) do
        nil -> row
        account_no -> %{row | account_no: account_no}
      end

    ECBPlatform.Integrity.translate(
      fn ->
        {1, [%{id: id}]} = TenantRepo.insert_all("m_loan", [row], returning: [:id])
        id
      end,
      %{},
      {"error.msg.unknown.data.integrity.issue", "Unknown data integrity issue with resource."}
    )
  end

  defp temporary_account_no,
    do: 19 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> binary_part(0, 19)

  # --- account number ---------------------------------------------------------------------------

  # A loan without an account number in the request gets nine digits from its id, with the prefix the
  # tenant's loan format asks for (the office name, the product's short name or a fixed one).
  defp generate_account_no!(id, p, product, client) do
    if blank_to_nil(Params.string(p, "accountNo")) == nil do
      format =
        TenantRepo.one(
          from(f in "c_account_number_format",
            where: f.account_type_enum == 2,
            select: %{prefix: f.prefix_type_enum, character: f.prefix_character}
          )
        )

      padded = String.pad_leading(Integer.to_string(id), 9, "0")

      account_no =
        case format do
          %{prefix: 1} -> prefixed(client_office_name(client), padded)
          %{prefix: 201} -> prefixed(product.short_name, padded)
          %{prefix: 401, character: char} -> fixed_prefix(char, id)
          _ -> padded
        end

      TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
        set: [account_no: account_no]
      )
    end

    :ok
  end

  defp client_office_name(%{office_id: office_id}),
    do: TenantRepo.one(from(o in "m_office", where: o.id == ^office_id, select: o.name))

  defp prefixed(nil, padded), do: padded
  defp prefixed(prefix, padded), do: String.slice(prefix, 0, 10) <> padded

  defp fixed_prefix(char, id) do
    prefix = String.slice(char || "", 0, 10)
    prefix <> String.pad_leading(Integer.to_string(id), max(9 - String.length(prefix), 0), "0")
  end

  # --- the schedule -------------------------------------------------------------------------------

  @doc false
  def insert_installments!(loan_id, schedule, user, now) do
    rows =
      for period <- schedule.periods do
        %{
          loan_id: loan_id,
          fromdate: period.from,
          duedate: period.due,
          installment: period.number,
          principal_amount: nil_if_zero(period.principal),
          interest_amount: nil_if_zero(period.interest),
          fee_charges_amount: nil_if_zero(period.fees),
          penalty_charges_amount: nil_if_zero(period.penalties),
          completed_derived: false,
          recalculated_interest_component: false,
          is_additional: false,
          is_down_payment: false,
          is_re_aged: false,
          created_by: user.id,
          last_modified_by: user.id,
          created_on_utc: now,
          last_modified_on_utc: now
        }
      end

    TenantRepo.insert_all("m_loan_repayment_schedule", rows)
    :ok
  end

  defp nil_if_zero(money), do: ECBMoney.amount_or_nil_if_zero(money)
end
