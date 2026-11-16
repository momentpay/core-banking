defmodule ECBApiFineract.Resources.LoanAccounts do
  @moduledoc """
  `/v1/loans`: loan accounts. Reading one loan (with the associations a caller asks for), a page of loans,
  submitting an application, and the steps before money moves (approve, undo approval, reject, withdraw)
  and deleting an application. Answers as Fineract's `LoansApiResource` does.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Charges, Read, Write}
  alias ECBLoans.{LoanEnums, Loans}
  alias ECBPlatform.Errors.UnrecognizedQueryParameter

  @resource "LOAN"

  @commands %{
    "approve" => "APPROVE",
    "undoapproval" => "APPROVALUNDO",
    "reject" => "REJECT",
    "withdrawnByApplicant" => "WITHDRAW",
    "disburse" => "DISBURSE",
    "undodisbursal" => "DISBURSALUNDO"
  }

  # The names `fields` can choose between (Fineract's response parameters for a loan).
  @choosable ~w(id accountNo status externalId clientId group loanProductId loanProductName
                loanProductDescription isLoanProductLinkedToFloatingRate fundId fundName loanPurposeId
                loanPurposeName loanOfficerId loanOfficerName currency principal totalOverpaid
                inArrearsTolerance termFrequency termPeriodFrequencyType numberOfRepayments repaymentEvery
                interestRatePerPeriod annualInterestRate repaymentFrequencyType
                transactionProcessingStrategyCode transactionProcessingStrategyName
                interestRateFrequencyType amortizationType interestType interestCalculationPeriodType
                allowPartialPeriodInterestCalculation expectedFirstRepaymentOnDate graceOnPrincipalPayment
                recurringMoratoriumOnPrincipalPeriods graceOnInterestPayment graceOnInterestCharged
                interestChargedFromDate timeline totalFeeChargesAtDisbursement summary repaymentSchedule
                transactions charges collateral guarantors meeting productOptions amortizationTypeOptions
                interestTypeOptions interestCalculationPeriodTypeOptions repaymentFrequencyTypeOptions
                repaymentFrequencyNthDayTypeOptions repaymentFrequencyDaysOfWeekTypeOptions
                termFrequencyTypeOptions interestRateFrequencyTypeOptions fundOptions
                repaymentStrategyOptions chargeOptions loanOfficerOptions loanPurposeOptions
                loanCollateralOptions chargeTemplate calendarOptions syncDisbursementWithMeeting
                loanCounter loanProductCounter notes originators accountLinkingOptions linkedAccount
                interestRateDifferential isFloatingInterestRate interestRatesPeriods lastClosedBusinessDate
                canUseForTopup isTopup loanIdToClose topupAmount clientActiveLoanOptions datatables rates
                multiDisburseDetails emiAmountVariations collectionData interestRecognitionOnDisbursementDate
                daysInYearCustomStrategy)

  # --- reads ----------------------------------------------------------------------------------

  @doc "`GET /loans`"
  def index(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      %{total: total, items: items} = Loans.list(conn.assigns.current_user, list_options(q))

      %{"totalFilteredRecords" => total, "pageItems" => Enum.map(items, &list_item/1)}
      |> only_fields(q)
    end)
  end

  @doc "`GET /loans/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> id |> Loans.fetch!() |> one(conn.query_params) end)
    end)
  end

  @doc "`GET /loans/external-id/:external_id`"
  def show_by_external_id(conn, external_id) do
    Read.respond(conn, @resource, fn ->
      case Loans.get_by_external_id(external_id) do
        nil -> {:error, Loans.not_found_by_external_id(external_id)}
        loan -> one(loan, conn.query_params)
      end
    end)
  end

  defp one(loan, q) do
    associations = associations(q["associations"])

    loan
    |> loan_json()
    |> with_associations(loan, associations)
    |> only_fields(q)
  end

  defp list_options(q) do
    [
      external_id: blank_to_nil(q["externalId"]),
      account_no: blank_to_nil(q["accountNo"]),
      hierarchy: blank_to_nil(q["underHierarchy"]),
      order_by: blank_to_nil(q["orderBy"]),
      sort_order: q["sortOrder"],
      limit: int(q["limit"]),
      offset: int(q["offset"])
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp int(nil), do: nil

  defp int(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp associations(nil), do: MapSet.new()

  defp associations(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> MapSet.new()

  # --- one loan as Fineract shows it ------------------------------------------------------------

  # a loan in a page leaves out the options and the term count of a single loan, and carries its delinquency
  @left_out_of_pages ~w(actualNoTerm collateral loanScheduleTypeOptions loanScheduleProcessingTypeOptions
                        daysInYearCustomStrategyOptions capitalizedIncomeCalculationTypeOptions
                        capitalizedIncomeStrategyOptions capitalizedIncomeTypeOptions
                        buyDownFeeCalculationTypeOptions buyDownFeeStrategyOptions
                        buyDownFeeIncomeTypeOptions overdueCharges paidInAdvance isRatesEnabled)

  @left_out_of_page_summaries ~w(totalMerchantRefund totalMerchantRefundReversed totalPayoutRefund
                                 totalPayoutRefundReversed totalGoodwillCredit totalGoodwillCreditReversed
                                 totalChargeAdjustment totalChargeAdjustmentReversed totalChargeback
                                 totalCreditBalanceRefund totalCreditBalanceRefundReversed
                                 totalRepaymentTransaction totalRepaymentTransactionReversed
                                 totalInterestPaymentWaiver totalInterestRefund totalUnpaidPayableDueInterest
                                 totalUnpaidPayableNotDueInterest)

  # a loan in a page shows its delinquency as nothing but zeros
  @page_delinquent_keys ~w(availableDisbursementAmount availableDisbursementAmountWithOverApplied pastDueDays
                           nextPaymentAmount delinquentDays delinquentAmount lastPaymentAmount
                           lastRepaymentAmount delinquentPrincipal delinquentInterest delinquentFee
                           delinquentPenalty)

  defp list_item(loan) do
    loan
    |> loan_json()
    |> Map.drop(@left_out_of_pages)
    |> Map.update("summary", nil, fn
      nil -> nil
      summary -> Map.drop(summary, @left_out_of_page_summaries)
    end)
    |> Map.put("delinquent", Map.new(@page_delinquent_keys, &{&1, 0}))
    |> then(&if(&1["summary"] == nil, do: Map.delete(&1, "summary"), else: &1))
  end

  @doc false
  def loan_json(l) do
    Loans.static()
    |> Map.merge(%{
      "id" => l.id,
      "accountNo" => l.account_no,
      "status" => Loans.status_json(l.loan_status_id),
      "clientId" => l.client_id,
      "clientAccountNo" => l.client_account_no,
      "clientName" => l.client_name,
      "clientOfficeId" => l.client_office_id,
      "loanProductId" => l.product_id,
      "loanProductName" => l.product_name,
      "isLoanProductLinkedToFloatingRate" => false,
      "loanType" => %{
        "id" => 1,
        "code" => "accountType.individual",
        "value" => "Individual"
      },
      "currency" => currency(l),
      "principal" => l.principal_amount,
      "approvedPrincipal" => l.approved_principal,
      "proposedPrincipal" => l.principal_amount_proposed,
      "netDisbursalAmount" => l.net_disbursal_amount,
      "termFrequency" => l.term_frequency,
      "termPeriodFrequencyType" => term_frequency(l.term_period_frequency_enum),
      "numberOfRepayments" => l.number_of_repayments,
      "actualNoTerm" => l.number_of_repayments,
      "repaymentEvery" => l.repay_every,
      "repaymentFrequencyType" => option(:repayment_frequency, l.repayment_period_frequency_enum),
      "interestRatePerPeriod" => l.nominal_interest_rate_per_period,
      "interestRateFrequencyType" =>
        option(:interest_frequency, l.interest_period_frequency_enum),
      "annualInterestRate" => l.annual_nominal_interest_rate,
      "amortizationType" => option(:amortization, l.amortization_method_enum),
      "interestType" => option(:interest_type, l.interest_method_enum),
      "interestCalculationPeriodType" =>
        option(:interest_period, l.interest_calculated_in_period_enum),
      "allowPartialPeriodInterestCalculation" => l.allow_partial_period_interest_calcualtion,
      "transactionProcessingStrategyCode" => l.loan_transaction_strategy_code,
      "transactionProcessingStrategyName" => l.loan_transaction_strategy_name,
      "timeline" => timeline(l),
      "daysInMonthType" => option(:days_in_month, l.days_in_month_enum),
      "daysInYearType" => option(:days_in_year, l.days_in_year_enum),
      "isInterestRecalculationEnabled" => l.interest_recalculation_enabled,
      "repaymentStartDateType" => option(:repayment_start, l.repayment_start_date_type_enum)
    })
    |> put("summary", summary(l))
    |> put("totalOverpaid", l.total_overpaid_derived)
    |> put("overpaidOnDate", l.overpaidon_date)
    |> Map.put("paidInAdvance", %{"paidInAdvance" => paid_in_advance(l)})
    |> put("loanProductCounter", product_counter(l))
    |> Map.put("inArrears", overdue(l).total != 0)
    |> put("externalId", l.external_id)
    |> put("graceOnPrincipalPayment", l.grace_on_principal_periods)
    |> put("graceOnInterestPayment", l.grace_on_interest_periods)
    |> put("graceOnInterestCharged", l.grace_interest_free_periods)
    |> put("expectedFirstRepaymentOnDate", l.expected_firstrepaymenton_date)
    |> put("interestChargedFromDate", l.interest_calculated_from_date)
    |> put("inArrearsTolerance", l.arrearstolerance_amount)
    |> put("fundId", l.fund_id)
    |> put("fundName", l.fund_name)
    |> put("loanOfficerId", l.loan_officer_id)
    |> put("loanOfficerName", l.loan_officer_name)
    |> put("loanPurposeId", l.loanpurpose_cv_id)
    |> put("loanPurposeName", l.loan_purpose_name)
  end

  # The running totals of a loan that has left the approval stage (all zero for one that never paid out)
  defp summary(%{loan_status_id: status}) when status in [100, 200], do: nil

  defp summary(l) do
    zero = 0
    overdue = overdue(l)

    %{
      "currency" => currency(l),
      "totalPrincipal" => l.principal_disbursed_derived,
      "totalCapitalizedIncome" => Decimal.new("0.0"),
      "totalCapitalizedIncomeAdjustment" => Decimal.new("0.0"),
      "principalDisbursed" => l.principal_disbursed_derived,
      "principalAdjustments" => l.principal_adjustments_derived,
      "principalPaid" => l.principal_repaid_derived,
      "principalWrittenOff" => l.principal_writtenoff_derived,
      "principalOutstanding" => l.principal_outstanding_derived,
      "principalOverdue" => overdue.principal,
      "interestCharged" => l.interest_charged_derived,
      "interestPaid" => l.interest_repaid_derived,
      "interestWaived" => l.interest_waived_derived,
      "interestWrittenOff" => l.interest_writtenoff_derived,
      "interestOutstanding" => l.interest_outstanding_derived,
      "interestOverdue" => overdue.interest,
      "feeChargesCharged" => l.fee_charges_charged_derived,
      "feeAdjustments" => Decimal.new("0.0"),
      "feeChargesDueAtDisbursementCharged" =>
        l.total_charges_due_at_disbursement_derived || Decimal.new("0.0"),
      "feeChargesPaid" => l.fee_charges_repaid_derived,
      "feeChargesWaived" => l.fee_charges_waived_derived,
      "feeChargesWrittenOff" => l.fee_charges_writtenoff_derived,
      "feeChargesOutstanding" => l.fee_charges_outstanding_derived,
      "feeChargesOverdue" => overdue.fees,
      "penaltyChargesCharged" => l.penalty_charges_charged_derived,
      "penaltyAdjustments" => Decimal.new("0.0"),
      "penaltyChargesPaid" => l.penalty_charges_repaid_derived,
      "penaltyChargesWaived" => l.penalty_charges_waived_derived,
      "penaltyChargesWrittenOff" => l.penalty_charges_writtenoff_derived,
      "penaltyChargesOutstanding" => l.penalty_charges_outstanding_derived,
      "penaltyChargesOverdue" => overdue.penalties,
      "totalExpectedRepayment" => l.total_expected_repayment_derived,
      "totalRepayment" => l.total_repayment_derived,
      "totalExpectedCostOfLoan" => l.total_expected_costofloan_derived,
      "totalCostOfLoan" => l.total_costofloan_derived,
      "totalWaived" => l.total_waived_derived,
      "totalWrittenOff" => l.total_writtenoff_derived,
      "totalOutstanding" => l.total_outstanding_derived,
      "totalOverdue" => overdue.total,
      "totalRecovered" => l.total_recovered_derived || zero,
      "totalMerchantRefund" => zero,
      "totalMerchantRefundReversed" => zero,
      "totalPayoutRefund" => zero,
      "totalPayoutRefundReversed" => zero,
      "totalGoodwillCredit" => zero,
      "totalGoodwillCreditReversed" => zero,
      "totalChargeAdjustment" => zero,
      "totalChargeAdjustmentReversed" => zero,
      "totalChargeback" => zero,
      "totalCreditBalanceRefund" => zero,
      "totalCreditBalanceRefundReversed" => zero,
      "totalRepaymentTransaction" => nonzero(repayment_transactions_total(l)),
      "totalRepaymentTransactionReversed" => nonzero(sum_transactions(l, 2, true)),
      "totalInterestPaymentWaiver" => zero,
      "totalInterestRefund" => zero,
      "totalUnpaidPayableDueInterest" => payable_due(l, overdue),
      "totalUnpaidPayableNotDueInterest" => accrued_not_due(l)
    }
    |> put("overdueSinceDate", overdue.since)
  end

  # the interest of the installment now running that has built up since it began, by days
  defp accrued_not_due(%{loan_status_id: 300} = l) do
    today = ECBPlatform.BusinessDate.current()

    l.id
    |> Loans.installments()
    |> Enum.find(
      &(Date.compare(&1.from_date, today) != :gt and Date.compare(&1.due_date, today) == :gt)
    )
    |> case do
      nil ->
        0

      r ->
        owed =
          outstanding(r.interest, r.interest_completed, r.interest_writtenoff, r.interest_waived)

        days = Date.diff(today, r.from_date)
        accrued = owed |> Decimal.mult(days) |> Decimal.div(Date.diff(r.due_date, r.from_date))
        if Decimal.eq?(accrued, 0), do: 0, else: Decimal.round(accrued, l.currency_digits)
    end
  end

  defp accrued_not_due(_loan), do: 0

  # the interest that has fallen due and is unpaid
  defp payable_due(%{loan_status_id: 300} = l, _overdue) do
    today = ECBPlatform.BusinessDate.current()

    l.id
    |> Loans.installments()
    |> Enum.filter(&(Date.compare(&1.due_date, today) != :gt))
    |> Enum.map(
      &outstanding(&1.interest, &1.interest_completed, &1.interest_writtenoff, &1.interest_waived)
    )
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> nonzero()
  end

  defp payable_due(_loan, _overdue), do: 0

  # what has been paid on installments that are not yet past due
  defp paid_in_advance(%{disbursedon_date: nil}), do: 0

  defp paid_in_advance(l) do
    today = ECBPlatform.BusinessDate.current()

    l.id
    |> Loans.installments()
    |> Enum.filter(&(Date.compare(&1.due_date, today) != :lt))
    |> Enum.map(&paid/1)
    |> Enum.reject(&Decimal.eq?(&1, 0))
    |> case do
      [] -> 0
      amounts -> Enum.reduce(amounts, &Decimal.add/2)
    end
  end

  # the sum of the repayments made, whatever they were allocated to
  defp repayment_transactions_total(l), do: sum_transactions(l, 2, false)

  # the sum of the transactions of a type, the standing ones or the reversed ones
  defp sum_transactions(l, type, reversed?) do
    l.id
    |> Loans.transactions()
    |> Enum.filter(&(&1.transaction_type_enum == type and &1.is_reversed == reversed?))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
  end

  # an amount that is only shown with decimals once it is more than nothing
  defp nonzero(amount), do: if(Decimal.eq?(amount, 0), do: 0, else: amount)

  # what is overdue: the unpaid part of every installment due before the business date
  defp overdue(l) do
    today = ECBPlatform.BusinessDate.current()

    due =
      if l.loan_status_id == Loans.status(:active) do
        l.id
        |> Loans.installments()
        |> Enum.filter(&(Date.compare(&1.due_date, today) == :lt and &1.completed != true))
      else
        []
      end

    if due == [] do
      %{principal: 0, interest: 0, fees: 0, penalties: 0, total: 0, since: nil}
    else
      sum = fn f -> due |> Enum.map(f) |> Enum.reduce(&Decimal.add/2) end
      none = Decimal.new(0)

      principal =
        sum.(
          &outstanding(&1.principal || none, &1.principal_completed, &1.principal_writtenoff, nil)
        )

      interest =
        sum.(
          &outstanding(
            &1.interest || none,
            &1.interest_completed,
            &1.interest_writtenoff,
            &1.interest_waived
          )
        )

      fees =
        sum.(
          &outstanding(
            &1.fee_charges || none,
            &1.fee_charges_completed,
            &1.fee_charges_writtenoff,
            &1.fee_charges_waived
          )
        )

      penalties =
        sum.(
          &outstanding(
            &1.penalty_charges || none,
            &1.penalty_charges_completed,
            &1.penalty_charges_writtenoff,
            &1.penalty_charges_waived
          )
        )

      overdue_totals(principal, interest, fees, penalties, due)
    end
  end

  defp overdue_totals(principal, interest, fees, penalties, due) do
    decimal = fn d -> if Decimal.eq?(d, 0), do: Decimal.new("0.0"), else: d end

    %{
      principal: principal,
      interest: interest,
      fees: decimal.(fees),
      penalties: decimal.(penalties),
      total: principal |> Decimal.add(interest) |> Decimal.add(fees) |> Decimal.add(penalties),
      since: due |> hd() |> Map.fetch!(:due_date)
    }
  end

  # a loan keeps the count it was given when it was paid out; one written off shows how many were paid out by then
  defp product_counter(%{disbursedon_date: nil}), do: nil
  defp product_counter(%{loan_status_id: 601} = l), do: l.product_loans_paid_out
  defp product_counter(l), do: l.loan_product_counter

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp currency(l) do
    Charges.currency(%{
      code: l.currency_code,
      name: l.currency_name,
      decimal_places: l.currency_digits,
      multiples_of: l.currency_multiplesof,
      display_symbol: l.currency_symbol,
      name_code: l.currency_name_code
    })
  end

  defp option(kind, id) do
    case LoanEnums.option(kind, id) do
      nil -> nil
      %{id: id, code: code, value: value} -> %{"id" => id, "code" => code, "value" => value}
    end
  end

  # the term is shown with the term-frequency names (`termFrequency.periodFrequencyType.months`)
  defp term_frequency(id) do
    case option(:repayment_frequency, id) do
      nil ->
        nil

      o ->
        %{o | "code" => String.replace_prefix(o["code"], "repaymentFrequency.", "termFrequency.")}
    end
  end

  defp timeline(l) do
    %{"submittedOnDate" => l.submittedon_date}
    |> person(
      "submittedBy",
      l.submitted_by_username,
      l.submitted_by_firstname,
      l.submitted_by_lastname
    )
    |> put("rejectedOnDate", l.rejectedon_date)
    |> person(
      "rejectedBy",
      l.rejected_by_username,
      l.rejected_by_firstname,
      l.rejected_by_lastname
    )
    |> put("withdrawnOnDate", l.withdrawnon_date)
    |> person(
      "withdrawnBy",
      l.withdrawn_by_username,
      l.withdrawn_by_firstname,
      l.withdrawn_by_lastname
    )
    |> put("approvedOnDate", l.approvedon_date)
    |> person(
      "approvedBy",
      l.approved_by_username,
      l.approved_by_firstname,
      l.approved_by_lastname
    )
    |> Map.put("expectedDisbursementDate", l.expected_disbursedon_date)
    |> put("actualDisbursementDate", l.disbursedon_date)
    |> person(
      "disbursedBy",
      l.disbursed_by_username,
      l.disbursed_by_firstname,
      l.disbursed_by_lastname
    )
    |> put("overpaidOnDate", l.overpaidon_date)
    |> put("closedOnDate", l.closedon_date)
    |> person("closedBy", l.closed_by_username, l.closed_by_firstname, l.closed_by_lastname)
    |> put("writeOffOnDate", l.writtenoffon_date)
    |> person("writeOffBy", l.closed_by_username, l.closed_by_firstname, l.closed_by_lastname)
    |> put("actualMaturityDate", l.maturedon_date)
    |> put("expectedMaturityDate", l.expected_maturedon_date)
  end

  defp person(map, _prefix, nil, _first, _last), do: map

  defp person(map, prefix, username, first, last) do
    map
    |> Map.put(prefix <> "Username", username)
    |> put(prefix <> "Firstname", first)
    |> put(prefix <> "Lastname", last)
  end

  # --- associations -----------------------------------------------------------------------------

  defp with_associations(body, loan, associations) do
    all? = MapSet.member?(associations, "all")
    body = if all?, do: with_accrual_totals(body), else: body
    wants? = fn name -> all? or MapSet.member?(associations, name) end

    body
    |> maybe(wants?.("repaymentSchedule"), fn b ->
      b
      |> Map.put("repaymentSchedule", repayment_schedule(loan))
      |> Map.put("disbursementDetails", [])
      |> Map.put("emiAmountVariations", [])
    end)
    |> maybe(wants?.("transactions"), fn b ->
      Map.put(
        b,
        "transactions",
        loan.id
        |> Loans.transactions()
        |> Enum.reject(&undone_payout?/1)
        |> Enum.map(&transaction_json(&1, loan))
      )
    end)
    |> maybe(all?, fn b ->
      b
      |> put(
        "notes",
        loan.id |> Loans.notes() |> Enum.map(&note/1) |> then(&if(&1 == [], do: nil, else: &1))
      )
      |> Map.put("disbursementDetails", [])
      |> Map.put("originators", [])
      |> Map.put("emiAmountVariations", [])
      |> Map.put("loanTermVariations", [])
      |> Map.put("delinquent", delinquent(loan))
    end)
  end

  @type_flags ~w(disbursement repaymentAtDisbursement repayment merchantIssuedRefund payoutRefund goodwillCredit
                 interestPaymentWaiver chargeRefund contra waiveInterest waiveCharges accrual writeOff
                 recoveryRepayment initiateTransfer approveTransfer withdrawTransfer rejectTransfer chargePayment
                 refund refundForActiveLoans creditBalanceRefund chargeAdjustment chargeback chargeoff downPayment
                 reAge reAmortize accrualActivity interestRefund accrualAdjustment capitalizedIncome
                 capitalizedIncomeAmortization capitalizedIncomeAdjustment capitalizedIncomeAmortizationAdjustment
                 contractTermination loanWithdrawal buyDownFee buyDownFeeAdjustment buyDownFeeAmortization
                 buyDownFeeAmortizationAdjustment)

  # id => {code, value, the flag that is on}
  @transaction_types %{
    1 => {"loanTransactionType.disbursement", "Disbursement", "disbursement"},
    2 => {"loanTransactionType.repayment", "Repayment", "repayment"},
    3 => {"loanTransactionType.contra", "Contra", "contra"},
    4 => {"loanTransactionType.waiver", "Waive interest", "waiveInterest"},
    5 =>
      {"loanTransactionType.repaymentAtDisbursement", "Repayment at disbursement",
       "repaymentAtDisbursement"},
    6 => {"loanTransactionType.writeOff", "Close (as written-off)", "writeOff"},
    8 => {"loanTransactionType.recoveryRepayment", "Recovery Repayment", "recoveryRepayment"},
    9 => {"loanTransactionType.waiveCharges", "Waive loan charges", "waiveCharges"},
    10 => {"loanTransactionType.accrual", "Accrual", "accrual"}
  }

  @doc false
  def transaction_json(t, loan) do
    zero = 0
    {code, value, flag} = Map.fetch!(@transaction_types, t.transaction_type_enum)
    flags = Map.new(@type_flags, &{&1, &1 == flag})

    %{
      "id" => t.id,
      "loanId" => t.loan_id,
      "officeId" => t.office_id,
      "officeName" => t.office_name,
      "type" =>
        Map.merge(%{"id" => t.transaction_type_enum, "code" => code, "value" => value}, flags),
      "date" => t.transaction_date,
      "currency" => currency(loan),
      "amount" => t.amount,
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "principalPortion" => t.principal_portion_derived || zero,
      "interestPortion" => t.interest_portion_derived || zero,
      "feeChargesPortion" => t.fee_charges_portion_derived || zero,
      "penaltyChargesPortion" => t.penalty_charges_portion_derived || zero,
      "overpaymentPortion" => t.overpayment_portion_derived || zero,
      "unrecognizedIncomePortion" => t.unrecognized_income_portion || zero,
      "outstandingLoanBalance" => t.outstanding_loan_balance_derived || zero,
      "submittedOnDate" => t.submitted_on_date,
      "manuallyReversed" => t.manually_adjusted_or_reversed == true,
      "loanChargePaidByList" => [],
      "transactionRelations" => []
    }
    |> put("externalLoanId", loan.external_id)
    |> put("externalId", t.external_id)
    |> put("reversalExternalId", t.reversal_external_id)
    |> put("reversedOnDate", t.reversed_on_date)
    |> put("paymentDetailData", payment_detail(t))
  end

  defp payment_detail(%{payment_detail_id: nil}), do: nil

  defp payment_detail(t) do
    %{"id" => t.payment_detail_id}
    |> put("paymentType", payment_type(t))
    |> put("accountNumber", t.account_number)
    |> put("checkNumber", t.check_number)
    |> put("routingCode", t.routing_code)
    |> put("receiptNumber", t.receipt_number)
    |> put("bankNumber", t.bank_number)
  end

  defp payment_type(%{payment_type_id: nil}), do: nil

  defp payment_type(t), do: %{"id" => t.payment_type_id, "name" => t.payment_type_name}

  @doc "`GET /loans/:id/transactions/:transaction_id`"
  def show_transaction(conn, raw_id, raw_tid) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, tid} <- Write.path_id(raw_tid) do
      Read.respond(conn, @resource, fn -> one_transaction(id, tid, conn.query_params) end)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp one_transaction(id, tid, q) do
    loan = Loans.fetch!(id)

    case Loans.transaction(id, tid) do
      nil -> {:error, Loans.transaction_not_found(tid)}
      t -> t |> transaction_json(loan) |> only_fields(q)
    end
  end

  # asked for with all its associations, an active loan shows the interest not yet due as decimals
  defp with_accrual_totals(%{"summary" => summary, "status" => %{"id" => status}} = body)
       when status in [300, 600, 601, 700] do
    zero = if body["currency"]["decimalPlaces"] == 0, do: 0, else: Decimal.new("0.0")

    fix = fn
      0 -> zero
      other -> other
    end

    today = ECBPlatform.BusinessDate.current()

    paid? =
      Enum.any?(Loans.installments(body["id"]), &(Date.compare(&1.due_date, today) != :gt))

    summary = Map.update!(summary, "totalUnpaidPayableNotDueInterest", fix)

    summary =
      if paid?,
        do:
          Map.update!(
            summary,
            "totalUnpaidPayableDueInterest",
            &if(&1 == 0, do: Decimal.new("0.0"), else: &1)
          ),
        else: summary

    %{body | "summary" => summary}
  end

  defp with_accrual_totals(body), do: body

  # a payout that was undone leaves no transaction in what the loan shows
  defp undone_payout?(t), do: t.is_reversed and t.transaction_type_enum in [1, 10]

  defp maybe(body, true, fun), do: fun.(body)
  defp maybe(body, _false, _fun), do: body

  defp note(n) do
    %{
      "id" => n.id,
      "clientId" => n.client_id,
      "loanId" => n.loan_id,
      "noteType" => note_type(n.note_type_enum),
      "note" => n.note,
      "createdById" => n.created_by,
      "createdByUsername" => n.created_by_username,
      "createdOn" => n.created_on_utc,
      "updatedById" => n.last_modified_by,
      "updatedByUsername" => n.modified_by_username,
      "updatedOn" => n.last_modified_on_utc
    }
    |> put("loanTransactionId", n.loan_transaction_id)
  end

  defp note_type(200), do: %{"id" => 200, "code" => "noteType.loan", "value" => "Loan note"}

  defp note_type(300),
    do: %{"id" => 300, "code" => "noteType.loan.transaction", "value" => "Loan transaction note"}

  defp delinquent(loan) do
    zero = 0
    today = ECBPlatform.BusinessDate.current()
    active? = loan.disbursedon_date != nil

    unpaid =
      if active?, do: Enum.reject(Loans.installments(loan.id), &(&1.completed == true)), else: []

    late = Enum.filter(unpaid, &(Date.compare(&1.due_date, today) == :lt))
    last = last_repayment(loan)

    %{
      "availableDisbursementAmount" => if(active?, do: Decimal.new("0.0"), else: zero),
      "availableDisbursementAmountWithOverApplied" =>
        if(active?, do: Decimal.new("0.0"), else: zero),
      "pastDueDays" => zero,
      "nextPaymentAmount" => zero,
      "delinquentDays" => zero,
      "delinquentAmount" => zero,
      "lastPaymentAmount" => zero,
      "lastRepaymentAmount" => zero,
      "delinquentPrincipal" => zero,
      "delinquentInterest" => zero,
      "delinquentFee" => zero,
      "delinquentPenalty" => zero
    }
    |> then(&if(active?, do: Map.put(&1, "delinquencyPausePeriods", []), else: &1))
    |> put("nextPaymentDueDate", next_payment_due(unpaid, late, last || loan_written_off(loan)))
    |> arrears(late, today)
    |> last_payment(last)
  end

  # the next installment's date; with nothing owed, or a payment made on top of arrears, the day of the last payment
  defp next_payment_due([], _late, nil), do: nil
  defp next_payment_due([], _late, %{} = last), do: last.transaction_date
  defp next_payment_due([first | _], [], _last), do: first.due_date
  defp next_payment_due([first | _], _late, nil), do: first.due_date
  defp next_payment_due(_unpaid, _late, last), do: last.transaction_date

  defp arrears(map, [], _today), do: map

  defp arrears(map, [first | _] = late, today) do
    days = Date.diff(today, first.due_date)
    sum = fn f -> late |> Enum.map(f) |> Enum.reduce(&Decimal.add/2) end
    zero = Decimal.new(0)

    principal =
      sum.(&outstanding(&1.principal, &1.principal_completed, &1.principal_writtenoff, nil))

    interest =
      sum.(
        &outstanding(
          &1.interest,
          &1.interest_completed,
          &1.interest_writtenoff,
          &1.interest_waived
        )
      )

    fee =
      sum.(
        &outstanding(
          &1.fee_charges,
          &1.fee_charges_completed,
          &1.fee_charges_writtenoff,
          &1.fee_charges_waived
        )
      )

    penalty =
      sum.(
        &outstanding(
          &1.penalty_charges,
          &1.penalty_charges_completed,
          &1.penalty_charges_writtenoff,
          &1.penalty_charges_waived
        )
      )

    map
    |> Map.merge(%{
      "pastDueDays" => days,
      "pastDueDate" => first.due_date,
      "delinquentDays" => days,
      "delinquentDate" => first.due_date,
      "delinquentAmount" =>
        principal |> Decimal.add(interest) |> Decimal.add(fee) |> Decimal.add(penalty),
      "delinquentPrincipal" => principal,
      "delinquentInterest" => interest,
      "delinquentFee" => if(Decimal.eq?(fee, zero), do: Decimal.new("0.0"), else: fee),
      "delinquentPenalty" => if(Decimal.eq?(penalty, zero), do: Decimal.new("0.0"), else: penalty)
    })
  end

  # a loan written off with nothing paid has its write-off day where a last payment would be
  defp loan_written_off(%{writtenoffon_date: nil}), do: nil
  defp loan_written_off(loan), do: %{transaction_date: loan.writtenoffon_date}

  defp last_repayment(loan) do
    loan.id
    |> Loans.transactions()
    |> Enum.filter(&(&1.transaction_type_enum == 2 and not &1.is_reversed))
    |> List.last()
  end

  defp last_payment(map, nil), do: map

  defp last_payment(map, t) do
    Map.merge(map, %{
      "lastPaymentDate" => t.transaction_date,
      "lastPaymentAmount" => t.amount,
      "lastRepaymentDate" => t.transaction_date,
      "lastRepaymentAmount" => t.amount
    })
  end

  # --- the repayment schedule of a stored loan ---------------------------------------------------

  defp repayment_schedule(loan) do
    rows = Loans.installments(loan.id)
    today = ECBPlatform.BusinessDate.current()
    zero = Decimal.new("0.0")

    {periods, _balance} =
      Enum.map_reduce(rows, loan.principal_amount, fn r, balance ->
        balance = Decimal.sub(balance, r.principal || zero)
        {period(r, balance, today), balance}
      end)

    rows
    |> totals(loan)
    |> Map.put("periods", [disbursement(loan, today) | periods])
    |> round_totals(loan.currency_digits)
  end

  defp term_in_days([], _loan), do: 0

  defp term_in_days(rows, loan),
    do:
      Date.diff(List.last(rows).due_date, loan.disbursedon_date || loan.expected_disbursedon_date)

  defp totals(rows, loan) do
    zero = Decimal.new("0.0")
    sum = fn f -> Enum.reduce(rows, zero, fn r, acc -> Decimal.add(acc, f.(r) || zero) end) end
    principal = sum.(& &1.principal)
    interest = sum.(& &1.interest)
    fees = sum.(& &1.fee_charges)
    penalties = sum.(& &1.penalty_charges)

    %{
      "currency" => currency(loan),
      "loanTermInDays" => term_in_days(rows, loan),
      "totalPrincipalDisbursed" => loan.principal_amount,
      "totalPrincipalExpected" => principal,
      "totalPrincipalPaid" => sum.(& &1.principal_completed),
      "totalInterestCharged" => interest,
      "totalFeeChargesCharged" => fees,
      "totalPenaltyChargesCharged" => penalties,
      "totalWaived" => sum.(&waived/1),
      "totalWrittenOff" => sum.(&written_off/1),
      "totalRepaymentExpected" =>
        Enum.reduce([interest, fees, penalties], principal, &Decimal.add(&2, &1)),
      "totalRepayment" => sum.(&paid/1),
      "totalPaidInAdvance" => sum.(& &1.paid_in_advance),
      "totalPaidLate" => sum.(& &1.paid_late),
      "totalOutstanding" =>
        Enum.reduce(rows, zero, fn r, acc -> Decimal.add(acc, outstanding(r)) end),
      "totalCredits" => zero
    }
  end

  # the totals of a schedule are shown with the currency's decimals (`76118` for a yen loan), its periods as stored
  defp round_totals(schedule, digits) do
    Map.new(schedule, fn
      {"periods", _} = periods -> periods
      {key, value} -> {key, round_money(value, digits)}
    end)
  end

  # Amounts of a schedule are shown with the currency's decimals (`76118` for a yen loan); a zero that
  # is not an amount of money, or one with fewer decimals already, is left as it is
  defp round_money(%Decimal{exp: exp} = d, digits) when exp < -digits,
    do: Decimal.round(d, digits)

  defp round_money(%{__struct__: _} = other, _digits), do: other

  defp round_money(map, digits) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, round_money(v, digits)} end)

  defp round_money(list, digits) when is_list(list), do: Enum.map(list, &round_money(&1, digits))
  defp round_money(other, _digits), do: other

  # Before the loan is paid out the disbursement period shows what is outstanding; afterwards what was paid.
  defp disbursement(loan, today) do
    zero = Decimal.new("0.0")

    %{
      "dueDate" => loan.disbursedon_date || loan.expected_disbursedon_date,
      "principalDisbursed" => loan.principal_amount,
      "principalLoanBalanceOutstanding" => loan.principal_amount,
      "feeChargesDue" => zero,
      "totalOriginalDueForPeriod" => zero,
      "totalDueForPeriod" => zero,
      "totalActualCostOfLoanForPeriod" => zero,
      "downPaymentPeriod" => false
    }
    |> Map.merge(
      if loan.disbursedon_date,
        do: %{"feeChargesPaid" => zero, "totalPaidForPeriod" => zero},
        else: %{"feeChargesOutstanding" => zero, "totalOutstandingForPeriod" => zero}
    )
    |> put(
      "totalOverdue",
      if(
        loan.disbursedon_date == nil and
          Date.compare(loan.expected_disbursedon_date, today) == :lt,
        do: zero
      )
    )
  end

  defp period(r, balance, today) do
    zero = Decimal.new(0)
    n = fn v -> v || zero end
    principal = n.(r.principal)
    interest = n.(r.interest)
    fees = n.(r.fee_charges)
    penalties = n.(r.penalty_charges)
    total = principal |> Decimal.add(interest) |> Decimal.add(fees) |> Decimal.add(penalties)
    out = outstanding(r)

    %{
      "period" => r.installment,
      "fromDate" => r.from_date,
      "dueDate" => r.due_date,
      "complete" => r.completed == true,
      "daysInPeriod" => Date.diff(r.due_date, r.from_date),
      "principalOriginalDue" => principal,
      "principalDue" => principal,
      "principalPaid" => n.(r.principal_completed),
      "principalWrittenOff" => n.(r.principal_writtenoff),
      "principalOutstanding" =>
        outstanding(principal, r.principal_completed, r.principal_writtenoff, nil),
      "principalLoanBalanceOutstanding" => balance,
      "interestOriginalDue" => interest,
      "interestDue" => interest,
      "interestPaid" => n.(r.interest_completed),
      "interestWaived" => n.(r.interest_waived),
      "interestWrittenOff" => n.(r.interest_writtenoff),
      "interestOutstanding" =>
        outstanding(interest, r.interest_completed, r.interest_writtenoff, r.interest_waived),
      "feeChargesDue" => fees,
      "feeChargesPaid" => n.(r.fee_charges_completed),
      "feeChargesWaived" => n.(r.fee_charges_waived),
      "feeChargesWrittenOff" => n.(r.fee_charges_writtenoff),
      "feeChargesOutstanding" =>
        outstanding(fees, r.fee_charges_completed, r.fee_charges_writtenoff, r.fee_charges_waived),
      "penaltyChargesDue" => penalties,
      "penaltyChargesPaid" => n.(r.penalty_charges_completed),
      "penaltyChargesWaived" => n.(r.penalty_charges_waived),
      "penaltyChargesWrittenOff" => n.(r.penalty_charges_writtenoff),
      "penaltyChargesOutstanding" =>
        outstanding(
          penalties,
          r.penalty_charges_completed,
          r.penalty_charges_writtenoff,
          r.penalty_charges_waived
        ),
      "totalOriginalDueForPeriod" => total,
      "totalDueForPeriod" => total,
      "totalPaidForPeriod" => paid(r),
      "totalPaidInAdvanceForPeriod" => n.(r.paid_in_advance),
      "totalPaidLateForPeriod" => n.(r.paid_late),
      "totalWaivedForPeriod" => waived(r),
      "totalWrittenOffForPeriod" => written_off(r),
      "totalOutstandingForPeriod" => out,
      "totalActualCostOfLoanForPeriod" => Decimal.add(interest, fees),
      "totalInstallmentAmountForPeriod" => total,
      "totalCredits" => zero,
      "totalAccruedInterest" => zero,
      "downPaymentPeriod" => false
    }
    |> put("obligationsMetOnDate", r.obligations_met_on)
    |> put("totalOverdue", if(Date.compare(r.due_date, today) == :lt, do: out))
  end

  defp outstanding(nil, _paid, _written_off, _waived), do: Decimal.new(0)

  defp outstanding(due, paid, written_off, waived) do
    zero = Decimal.new(0)

    due
    |> Decimal.sub(paid || zero)
    |> Decimal.sub(written_off || zero)
    |> Decimal.sub(waived || zero)
  end

  defp outstanding(r) do
    [
      outstanding(r.principal, r.principal_completed, r.principal_writtenoff, nil),
      outstanding(r.interest, r.interest_completed, r.interest_writtenoff, r.interest_waived),
      outstanding(
        r.fee_charges,
        r.fee_charges_completed,
        r.fee_charges_writtenoff,
        r.fee_charges_waived
      ),
      outstanding(
        r.penalty_charges,
        r.penalty_charges_completed,
        r.penalty_charges_writtenoff,
        r.penalty_charges_waived
      )
    ]
    |> Enum.reduce(&Decimal.add/2)
  end

  defp paid(r),
    do:
      total([
        r.principal_completed,
        r.interest_completed,
        r.fee_charges_completed,
        r.penalty_charges_completed
      ])

  defp waived(r), do: total([r.interest_waived, r.fee_charges_waived, r.penalty_charges_waived])

  defp written_off(r),
    do:
      total([
        r.principal_writtenoff,
        r.interest_writtenoff,
        r.fee_charges_writtenoff,
        r.penalty_charges_writtenoff
      ])

  # a sum of amounts that may all be missing: nothing at all is a plain zero
  defp total(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> Decimal.new(0)
      present -> Enum.reduce(present, &Decimal.add/2)
    end
  end

  # --- fields -----------------------------------------------------------------------------------

  defp only_fields({:error, _} = error, _q), do: error

  defp only_fields(body, q) do
    case q["fields"] do
      fields when is_binary(fields) and fields != "" ->
        wanted = fields |> String.split(",") |> Enum.map(&String.trim/1)
        drop = MapSet.new(@choosable -- wanted)
        filter(body, drop)

      _ ->
        body
    end
  end

  defp filter(%{__struct__: _} = struct, _drop), do: struct

  defp filter(map, drop) when is_map(map),
    do: for({k, v} <- map, not MapSet.member?(drop, k), into: %{}, do: {k, filter(v, drop)})

  defp filter(list, drop) when is_list(list), do: Enum.map(list, &filter(&1, drop))
  defp filter(other, _drop), do: other

  # --- writes -----------------------------------------------------------------------------------

  @doc "`POST /loans`: submits a loan application."
  def submit(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`POST /loans/:id?command=...`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      command = conn.query_params["command"]

      case Map.fetch(@commands, command) do
        {:ok, action} ->
          Write.execute(conn, @resource, action, id: id)

        :error ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: command,
            allowed: []
          })
      end
    end)
  end

  @doc "`POST /loans/:id/transactions?command=...`"
  def transaction_command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      case conn.query_params["command"] do
        "repayment" ->
          Write.execute(conn, @resource, "REPAYMENT", id: id)

        "waiveinterest" ->
          Write.execute(conn, @resource, "WAIVEINTERESTPORTION", id: id)

        "writeoff" ->
          Write.execute(conn, @resource, "WRITEOFF", id: id)

        command ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: command,
            allowed: []
          })
      end
    end)
  end

  @doc "`POST /loans/:id/transactions/:transaction_id?command=...`: any command but the named ones adjusts."
  def adjust_transaction(conn, raw_id, raw_tid) do
    Write.with_path_id(conn, raw_id, fn id ->
      Write.with_path_id(conn, raw_tid, fn tid ->
        Write.execute(conn, @resource, "ADJUST", id: id, subentity_id: tid)
      end)
    end)
  end

  @doc "`DELETE /loans/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))
end
