defmodule ECBApiFineract.Resources.LoanAccounts do
  @moduledoc """
  `/v1/loans`: loan accounts. Reading one loan (with the associations a caller asks for), a page of loans,
  submitting an application, and the steps before money moves (approve, undo approval, reject, withdraw)
  and deleting an application. Answers as Fineract's `LoansApiResource` does.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Charges, Delinquency, LoanProducts, Read, Write}
  alias ECBLoans.Delinquency.Actions
  alias ECBLoans.{LoanEnums, Loans}
  alias ECBPlatform.Errors.UnrecognizedQueryParameter

  @resource "LOAN"

  @commands %{
    "approve" => "APPROVE",
    "assignloanofficer" => "UPDATELOANOFFICER",
    "unassignloanofficer" => "REMOVELOANOFFICER",
    "undoapproval" => "APPROVALUNDO",
    "reject" => "REJECT",
    "withdrawnByApplicant" => "WITHDRAW",
    "disburse" => "DISBURSE",
    "undodisbursal" => "DISBURSALUNDO",
    "undolastdisbursal" => "DISBURSALLASTUNDO",
    "assigndelinquency" => "UPDATEDELINQUENCY"
  }

  # The names `fields` can choose between (Fineract's response parameters for a loan).
  # the names `fields=` can take out of a single transaction (those Fineract's serializer knows)
  @transaction_choosable ~w(id type date currency amount externalId reversalExternalId reversedOnDate classification
                            numberOfFutureInstallments numberOfPastInstallments nextInstallmentDueDate
                            calculatedStartDate)

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
    |> Map.put("overdueCharges", overdue_charges(loan.product_id))
    |> with_associations(loan, associations)
    |> only_fields(q)
  end

  # the charges the loan's product has for overdue installments
  defp overdue_charges(product_id) do
    product_id
    |> LoanProducts.detail()
    |> Map.fetch!("charges")
    |> Enum.filter(&(&1["chargeTimeType"]["id"] == 9))
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
      "actualNoTerm" => actual_term(l),
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
      "repaymentStartDateType" => option(:repayment_start, l.repayment_start_date_type_enum),
      "feeChargesAtDisbursementCharged" =>
        l.total_charges_due_at_disbursement_derived || Decimal.new("0.0")
    })
    |> put("summary", summary(l))
    |> Map.put("multiDisburseLoan", l.multi_disburse == true)
    |> Map.put("disallowExpectedDisbursements", l.disallow_expected_disbursements == true)
    |> put("maxOutstandingLoanBalance", l.max_outstanding_loan_balance)
    |> Map.put("chargedOff", l.is_charged_off == true)
    |> put("subStatus", sub_status(l.loan_sub_status_id))
    |> put("totalOverpaid", l.total_overpaid_derived)
    |> put("overpaidOnDate", l.overpaidon_date)
    |> Map.put("paidInAdvance", %{"paidInAdvance" => paid_in_advance(l)})
    |> put("loanProductCounter", product_counter(l))
    |> Map.put("inArrears", overdue(l).since != nil)
    |> put("externalId", l.external_id)
    |> put("graceOnArrearsAgeing", l.grace_on_arrears_ageing)
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
    |> put("delinquencyRange", Delinquency.loan_range(l.id))
    |> Map.put("isNPA", l.is_npa == true)
  end

  # the installments the loan has now, not counting those made for charges past the last one (a loan settled early
  # has fewer than it was made for, one that was rescheduled may have more)
  defp actual_term(l), do: ECBLoans.Loans.actual_term(l.id)

  defp sub_status(100),
    do: %{
      "id" => 100,
      "code" => "loanSubStatus.loanSubStatusType.foreclosed",
      "value" => "Foreclosed"
    }

  defp sub_status(_other), do: nil

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
      "totalMerchantRefund" => nonzero(sum_transactions(l, 21, false)),
      "totalMerchantRefundReversed" => nonzero(sum_transactions(l, 21, true)),
      "totalPayoutRefund" => nonzero(sum_transactions(l, 22, false)),
      "totalPayoutRefundReversed" => nonzero(sum_transactions(l, 22, true)),
      "totalGoodwillCredit" => nonzero(sum_transactions(l, 23, false)),
      "totalGoodwillCreditReversed" => nonzero(sum_transactions(l, 23, true)),
      "totalChargeAdjustment" => zero,
      "totalChargeAdjustmentReversed" => zero,
      "totalChargeback" => zero,
      "totalCreditBalanceRefund" => nonzero(sum_transactions(l, 20, false)),
      "totalCreditBalanceRefundReversed" => nonzero(sum_transactions(l, 20, true)),
      "totalRepaymentTransaction" => nonzero(repayment_transactions_total(l)),
      "totalRepaymentTransactionReversed" => nonzero(sum_transactions(l, 2, true)),
      "totalInterestPaymentWaiver" => nonzero(sum_transactions(l, 31, false)),
      "totalInterestRefund" => zero,
      "totalUnpaidPayableDueInterest" => payable_due(l, overdue),
      "totalUnpaidPayableNotDueInterest" => accrued_not_due(l)
    }
    |> put("chargeOffReasonId", l.charge_off_reason_cv_id)
    |> put("chargeOffReason", l.charge_off_reason)
    |> put("overdueSinceDate", overdue.since)
  end

  # the interest of the installment now running that has built up since it began, by days,
  # less what was paid or waived of it
  defp accrued_not_due(%{loan_status_id: status} = l) when status in [300, 600, 601, 602, 700] do
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
        days = Date.diff(today, r.from_date)

        built =
          (r.interest || Decimal.new(0))
          |> Decimal.mult(days)
          |> Decimal.div(Date.diff(r.due_date, r.from_date))

        accrued =
          built |> Decimal.sub(r.interest_completed || 0) |> Decimal.sub(r.interest_waived || 0)

        if Decimal.compare(accrued, 0) != :gt,
          do: 0,
          else: Decimal.round(accrued, l.currency_digits)
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
    |> Enum.filter(
      &(&1.transaction_type_enum == type and &1.is_reversed == reversed? and
          (not reversed? or &1.manually_adjusted_or_reversed == true))
    )
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
  end

  # an amount that is only shown with decimals once it is more than nothing
  defp nonzero(amount), do: if(Decimal.eq?(amount, 0), do: 0, else: amount)

  # what is overdue, as recorded in the loan's arrears (see `ECBLoans.Loans.Arrears`: it can be out of date until
  # the nightly job runs, as in Fineract)
  defp overdue(l) do
    case ECBLoans.Loans.Arrears.get(l.id) do
      nil ->
        %{principal: 0, interest: 0, fees: 0, penalties: 0, total: 0, since: nil}

      arrears ->
        %{
          arrears
          | fees: with_decimals(arrears.fees),
            penalties: with_decimals(arrears.penalties)
        }
    end
  end

  # a zero fee or penalty is shown with a decimal, as Fineract does
  defp with_decimals(amount), do: if(Decimal.eq?(amount, 0), do: Decimal.new("0.0"), else: amount)

  # the count the loan has among the client's loans of the product, as Counters keeps it
  defp product_counter(%{disbursedon_date: nil}), do: nil
  defp product_counter(l), do: l.loan_product_counter

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  @doc "The loan's currency as Fineract shows it with a transaction."
  @spec currency_json(map) :: map
  def currency_json(l), do: currency(l)

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
    |> put("chargedOffOnDate", l.charged_off_on_date)
    |> person(
      "chargedOffBy",
      l.charged_off_by_username,
      l.charged_off_by_firstname,
      l.charged_off_by_lastname
    )
  end

  @doc "A charge of the loan as Fineract shows it."
  @spec charge_json(map, map) :: map
  def charge_json(c, loan), do: loan_charge(c, loan)

  # a charge of the loan as Fineract shows it
  defp loan_charge(c, loan) do
    zero = 0

    %{
      "id" => c.id,
      "chargeId" => c.charge_id,
      "name" => c.name,
      "chargeTimeType" => charge_option(:time, c.time),
      "submittedOnDate" => c.submitted_on,
      "chargeCalculationType" => charge_option(:calculation, c.calc),
      "percentage" => c.percentage || zero,
      "amountPercentageAppliedTo" => c.applied_to || zero,
      "currency" => loan_charge_currency(loan),
      "amount" => c.amount,
      "amountPaid" => c.paid || zero,
      "amountWaived" => c.waived_amount || zero,
      "amountWrittenOff" => c.written_off || zero,
      "amountOutstanding" => c.outstanding,
      "amountOrPercentage" => c.amount_or_percentage,
      "penalty" => c.penalty,
      "chargePaymentMode" => charge_option(:payment_mode, c.payment_mode),
      "paid" => c.is_paid,
      "waived" => c.waived,
      "chargePayable" => false,
      "loanId" => c.loan_id
    }
    |> put("dueDate", c.due_date)
  end

  defp relation(r, t) do
    %{
      "fromLoanTransaction" => t.id,
      "toLoanTransaction" => r.to,
      "relationType" => relation_type(r.type),
      "amount" => t.amount
    }
    |> put("paymentType", t.payment_type_name)
  end

  defp relation_type(1), do: "CHARGEBACK"
  defp relation_type(2), do: "CHARGE_ADJUSTMENT"
  defp relation_type(3), do: "REPLAYED"
  defp relation_type(4), do: "RELATED"
  defp relation_type(5), do: "ADJUSTMENT"

  defp paid_by(p, transaction_id) do
    %{
      "id" => p.id,
      "transactionId" => transaction_id,
      "amount" => p.amount,
      "chargeId" => p.loan_charge_id,
      "name" => p.name
    }
    |> put("installmentNumber", p.installment)
  end

  defp loan_charge_currency(loan), do: Map.delete(currency(loan), "inMultiplesOf")

  @doc "The loan's currency as shown with a charge or a collateral (without its multiples)."
  @spec charge_currency_json(map) :: map
  def charge_currency_json(loan), do: loan_charge_currency(loan)

  defp charge_option(kind, id) do
    option = apply(ECBCatalog.Charges.Enums, kind, [id])
    %{"id" => option.id, "code" => option.code, "value" => option.value}
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
    schedule? = all? or MapSet.member?(associations, "repaymentSchedule")
    body = if schedule?, do: with_accrual_totals(body), else: without_accrual_totals(body)
    wants? = fn name -> all? or MapSet.member?(associations, name) end

    body
    |> maybe(wants?.("repaymentSchedule"), fn b ->
      b
      |> Map.put("repaymentSchedule", repayment_schedule(loan))
      |> Map.put("disbursementDetails", disbursement_details(loan))
      |> Map.put("emiAmountVariations", [])
    end)
    |> maybe(wants?.("guarantors"), fn b ->
      # Fineract writes each guarantor of the loan as an empty object here
      case ECBLoans.Guarantors.count(loan.id) do
        0 -> b
        n -> Map.put(b, "guarantors", List.duplicate(%{}, n))
      end
    end)
    |> maybe(wants?.("charges"), fn b ->
      case Loans.charges(loan.id) do
        [] -> b
        charges -> Map.put(b, "charges", Enum.map(charges, &loan_charge(&1, loan)))
      end
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
      |> Map.put("disbursementDetails", disbursement_details(loan))
      |> Map.put("originators", [])
      |> Map.put("emiAmountVariations", [])
      |> Map.put("loanTermVariations", term_variations(loan))
      |> Map.put("delinquent", delinquent(loan))
    end)
  end

  # the tranches of a loan paid out in parts, by expected date
  defp disbursement_details(loan) do
    # what the loan's charges due at disbursement come to is shown against every tranche
    at_disbursement = for c <- ECBLoans.Loans.charges(loan.id), c.time == 1, do: c

    fees =
      Enum.reduce(at_disbursement, nil, fn c, sum ->
        if sum, do: Decimal.add(sum, c.amount), else: c.amount
      end)

    charge_ids = at_disbursement |> Enum.map_join(",", & &1.id)

    for t <- ECBLoans.Tranches.list(loan.id) do
      %{
        "id" => t.id,
        "loanId" => loan.id,
        "expectedDisbursementDate" => t.expected_date,
        "principal" => t.principal,
        "disburseChargeAmount" => fees || 0
      }
      |> put("loanChargeId", if(charge_ids == "", do: nil, else: charge_ids))
      |> put("actualDisbursementDate", t.disbursed_on)
      |> put("netDisbursalAmount", t.net_disbursal_amount)
    end
  end

  defp term_variations(loan),
    do:
      loan.id
      |> ECBLoans.RescheduleRequests.loan_variations()
      |> Enum.map(&ECBApiFineract.Resources.RescheduleLoans.variation/1)

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
      {"loanTransactionType.repaymentAtDisbursement", "Repayment (at time of disbursement)",
       "repaymentAtDisbursement"},
    6 => {"loanTransactionType.writeOff", "Close (as written-off)", "writeOff"},
    8 =>
      {"loanTransactionType.recoveryRepayment", "Repayment (after write-off)",
       "recoveryRepayment"},
    9 => {"loanTransactionType.waiveCharges", "Waive loan charges", "waiveCharges"},
    10 => {"loanTransactionType.accrual", "Accrual", "accrual"},
    27 => {"loanTransactionType.chargeOff", "Charge-off", "chargeoff"},
    34 => {"loanTransactionType.accrualAdjustment", "Accrual Adjustment", "accrualAdjustment"},
    20 =>
      {"loanTransactionType.creditBalanceRefund", "Credit Balance Refund", "creditBalanceRefund"},
    21 =>
      {"loanTransactionType.merchantIssuedRefund", "Merchant Issued Refund",
       "merchantIssuedRefund"},
    22 => {"loanTransactionType.payoutRefund", "Payout Refund", "payoutRefund"},
    24 => {"loanTransactionType.chargeRefund", "Charge Refund", "chargeRefund"},
    23 => {"loanTransactionType.goodwillCredit", "Goodwill Credit", "goodwillCredit"},
    31 =>
      {"loanTransactionType.interestPaymentWaiver", "Interest Payment Waiver",
       "interestPaymentWaiver"}
  }

  @doc "The type of a transaction as Fineract shows it: its id, code and value, and the flag of its kind."
  @spec transaction_type_json(integer) :: map
  def transaction_type_json(type_enum) do
    {code, value, flag} = Map.fetch!(@transaction_types, type_enum)
    flags = Map.new(@type_flags, &{&1, &1 == flag})
    Map.merge(%{"id" => type_enum, "code" => code, "value" => value}, flags)
  end

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
      "loanChargePaidByList" => Enum.map(Loans.paid_by(t.id), &paid_by(&1, t.id)),
      "transactionRelations" => Enum.map(Loans.relations(t.id), &relation(&1, t))
    }
    |> put("externalLoanId", loan.external_id)
    |> put("externalId", t.external_id)
    |> put("reversalExternalId", t.reversal_external_id)
    |> put("reversedOnDate", t.reversed_on_date)
    |> put("paymentDetailData", payment_detail(t))
  end

  defp payment_detail(%{payment_detail_id: nil}), do: nil

  # Fineract shows the id of the transaction as that of its payment details
  defp payment_detail(t) do
    %{"id" => t.id}
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

  @doc "`GET /loans/:id/transactions/external-id/:external_id`"
  def show_transaction_by_external_id(conn, raw_id, external_id) do
    case Write.path_id(raw_id) do
      {:ok, id} ->
        Read.respond(conn, @resource, fn ->
          one_transaction_by_external_id(id, external_id, conn.query_params)
        end)

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  @doc "`GET /loans/external-id/:loan_external_id/transactions/:transaction_id`"
  def show_transaction_of_external_loan(conn, loan_external_id, raw_tid) do
    case Write.path_id(raw_tid) do
      {:ok, tid} ->
        Read.respond(conn, @resource, fn ->
          external_loan_transaction(loan_external_id, tid, conn)
        end)

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  defp external_loan_transaction(loan_external_id, tid, conn) do
    case Loans.get_by_external_id(loan_external_id) do
      nil -> {:error, Loans.not_found_by_external_id(loan_external_id)}
      loan -> one_transaction(loan.id, tid, conn.query_params)
    end
  end

  @doc "`GET /loans/external-id/:loan_external_id/transactions/external-id/:external_id`"
  def show_transaction_by_both_external_ids(conn, loan_external_id, external_id) do
    Read.respond(conn, @resource, fn ->
      case Loans.get_by_external_id(loan_external_id) do
        nil ->
          {:error, Loans.not_found_by_external_id(loan_external_id)}

        loan ->
          one_transaction_by_external_id(loan.id, external_id, conn.query_params)
      end
    end)
  end

  defp one_transaction_by_external_id(id, external_id, q) do
    loan = Loans.fetch!(id)

    case Loans.transaction_by_external_id(id, external_id) do
      nil -> {:error, Loans.transaction_not_found_by_external_id(external_id)}
      t -> t |> transaction_json(loan) |> only_fields(q, @transaction_choosable)
    end
  end

  @doc "`GET /loans/:id/transactions`: a page of the loan's transactions."
  def transactions(conn, raw_id) do
    case Write.path_id(raw_id) do
      {:ok, id} ->
        Read.respond(conn, @resource, fn -> transaction_page(Loans.fetch!(id), conn) end)

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  @doc "`GET /loans/external-id/:external_id/transactions`"
  def transactions_by_external_id(conn, external_id) do
    Read.respond(conn, @resource, fn ->
      case Loans.get_by_external_id(external_id) do
        nil -> {:error, Loans.not_found_by_external_id(external_id)}
        loan -> transaction_page(loan, conn)
      end
    end)
  end

  # The transaction names Fineract's enum gives, shown with each transaction of a page
  @transaction_enum_names %{
    1 => "DISBURSEMENT",
    2 => "REPAYMENT",
    3 => "CONTRA",
    4 => "WAIVE_INTEREST",
    5 => "REPAYMENT_AT_DISBURSEMENT",
    6 => "WRITEOFF",
    8 => "RECOVERY_REPAYMENT",
    9 => "WAIVE_CHARGES",
    10 => "ACCRUAL",
    20 => "CREDIT_BALANCE_REFUND",
    21 => "MERCHANT_ISSUED_REFUND",
    22 => "PAYOUT_REFUND",
    23 => "GOODWILL_CREDIT",
    24 => "CHARGE_REFUND",
    27 => "CHARGE_OFF",
    31 => "INTEREST_PAYMENT_WAIVER",
    34 => "ACCRUAL_ADJUSTMENT"
  }

  # the types Fineract calls repayment types (`LoanTransactionType.isRepaymentType`); a page flags them
  @repayment_types [2, 21, 22, 23, 24, 26, 28]

  # A transaction as the page of them shows it (Jackson's rendering of the data class: dates as text, a value that
  # is not there left out, no currency names, no payment type)
  defp transaction_list_item(t, loan) do
    {code, value, flag} = Map.fetch!(@transaction_types, t.transaction_type_enum)
    flags = Map.new(@type_flags, &{&1, &1 == flag})

    flags = Map.put(flags, "repaymentType", t.transaction_type_enum in @repayment_types)

    %{
      "id" => t.id,
      "loanId" => t.loan_id,
      "externalLoanId" => loan.external_id || :null,
      "officeId" => t.office_id,
      "officeName" => t.office_name,
      "type" =>
        Map.merge(%{"id" => t.transaction_type_enum, "code" => code, "value" => value}, flags),
      "date" => Date.to_iso8601(t.transaction_date),
      "currency" => Map.take(currency(loan), ["code", "decimalPlaces", "inMultiplesOf"]),
      "amount" => t.amount,
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "externalId" => t.external_id || :null,
      "submittedOnDate" => Date.to_iso8601(t.submitted_on_date),
      "manuallyReversed" => t.manually_adjusted_or_reversed == true,
      "loanChargePaidByList" => Enum.map(Loans.paid_by(t.id), &paid_by(&1, t.id)),
      "transactionDate" => Date.to_iso8601(t.transaction_date),
      "transactionType" => Map.fetch!(@transaction_enum_names, t.transaction_type_enum),
      "reversalExternalId" => t.reversal_external_id || :null,
      "transactionRelations" => Enum.map(Loans.relations(t.id), &list_relation(&1, t))
    }
    |> put("paymentDetailData", list_payment_detail(t))
    |> put("principalPortion", t.principal_portion_derived)
    |> put("interestPortion", t.interest_portion_derived)
    |> put("feeChargesPortion", t.fee_charges_portion_derived)
    |> put("penaltyChargesPortion", t.penalty_charges_portion_derived)
    |> put("overpaymentPortion", t.overpayment_portion_derived)
    |> put("unrecognizedIncomePortion", t.unrecognized_income_portion)
    |> put("outstandingLoanBalance", t.outstanding_loan_balance_derived)
    |> put("reversedOnDate", t.reversed_on_date && Date.to_iso8601(t.reversed_on_date))
  end

  defp list_relation(r, t) do
    %{
      "fromLoanTransaction" => t.id,
      "toLoanTransaction" => r.to,
      "relationType" => relation_type(r.type),
      "amount" => t.amount
    }
  end

  defp list_payment_detail(%{payment_detail_id: nil}), do: nil

  defp list_payment_detail(t) do
    %{"id" => t.payment_detail_id}
    |> put("accountNumber", t.account_number)
    |> put("checkNumber", t.check_number)
    |> put("routingCode", t.routing_code)
    |> put("receiptNumber", t.receipt_number)
    |> put("bankNumber", t.bank_number)
  end

  @default_page_size 50

  # Spring's page of the transactions: `page` (from 0), `size` and `sort=property[,asc|desc]` (more than once)
  defp transaction_page(loan, conn) do
    build_page(loan, conn.query_string |> URI.query_decoder() |> Enum.to_list())
  rescue
    error in [ECBPlatform.Errors.ServerError, ECBApiFineract.Errors.PathNotFound] ->
      {:error, error}
  end

  defp build_page(loan, query) do
    page = page_number(query, "page", 0, 0)
    size = page_number(query, "size", @default_page_size, 1)
    sort = sort_orders(query)
    %{total: total, items: items} = Loans.transactions_page(loan.id, page, size, sort)
    pages = if total == 0, do: 0, else: div(total + size - 1, size)

    sorted = %{
      "empty" => sort == [],
      "sorted" => sort != [],
      "unsorted" => sort == []
    }

    %{
      "content" => Enum.map(items, &transaction_list_item(&1, loan)),
      "pageable" => %{
        "pageNumber" => page,
        "pageSize" => size,
        "sort" => sorted,
        "offset" => page * size,
        "paged" => true,
        "unpaged" => false
      },
      "last" => page + 1 >= pages,
      "totalElements" => total,
      "totalPages" => pages,
      "size" => size,
      "number" => page,
      "sort" => sorted,
      "first" => page == 0,
      "numberOfElements" => length(items),
      "empty" => items == []
    }
  end

  # a number that is not a whole number is not a request the application sees (404); one that is too small is a 500
  defp page_number(query, name, default, minimum) do
    case Enum.find(query, &(elem(&1, 0) == name)) do
      nil ->
        default

      {_, text} ->
        case Integer.parse(text) do
          {n, ""} when n >= minimum -> n
          {_, ""} -> raise ECBPlatform.Errors.ServerError
          _ -> raise ECBApiFineract.Errors.PathNotFound
        end
    end
  end

  defp sort_orders(query) do
    for {"sort", value} <- query do
      [property, direction] =
        case String.split(value, ",") do
          [property] -> [property, "asc"]
          [property, direction | _] -> [property, direction]
        end

      direction =
        case String.downcase(direction) do
          "asc" -> :asc
          "desc" -> :desc
          _ -> raise ECBPlatform.Errors.ServerError
        end

      if property in Loans.transaction_sort_properties(),
        do: {property, direction},
        else: raise(ECBPlatform.Errors.ServerError)
    end
  end

  defp one_transaction(id, tid, q) do
    loan = Loans.fetch!(id)

    case Loans.transaction(id, tid) do
      nil -> {:error, Loans.transaction_not_found(tid)}
      t -> t |> transaction_json(loan) |> only_fields(q, @transaction_choosable)
    end
  end

  # asked for with all its associations, an active loan shows the interest not yet due as decimals
  # the interest that is unpaid and due, and the part of the running installment's that is not due yet, are worked
  # out only when the loan is asked for with its repayment schedule (or all its associations); without, Fineract
  # shows nothing
  defp without_accrual_totals(%{"summary" => summary} = body) when is_map(summary) do
    %{
      body
      | "summary" =>
          summary
          |> Map.put("totalUnpaidPayableDueInterest", 0)
          |> Map.put("totalUnpaidPayableNotDueInterest", 0)
    }
  end

  defp without_accrual_totals(body), do: body

  defp with_accrual_totals(%{"summary" => summary, "status" => %{"id" => status}} = body)
       when status in [300, 600, 601, 602, 700] do
    zero = if body["currency"]["decimalPlaces"] == 0, do: 0, else: Decimal.new("0.0")

    fix = fn
      0 -> zero
      other -> other
    end

    today = ECBPlatform.BusinessDate.current()

    paid? =
      Enum.any?(Loans.installments(body["id"]), &(Date.compare(&1.due_date, today) != :gt))

    # once the last installment is past, Fineract's figure is a plain 0
    running? =
      Enum.any?(Loans.installments(body["id"]), &(Date.compare(&1.due_date, today) == :gt))

    summary =
      if running?,
        do: Map.update!(summary, "totalUnpaidPayableNotDueInterest", fix),
        else: summary

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
  # what the system took back (a payout undone, an accrual or a repayment replaced) is not shown
  defp undone_payout?(t), do: t.is_reversed and t.manually_adjusted_or_reversed != true

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

  # What the approval still allows to be paid out, with and without counting the tranches that are expected: for a
  # loan paid out in tranches the approval less what has been paid out, for another the fees due when it is
  # paid out.
  defp available_disbursement(loan, active?, zero) do
    case ECBLoans.Tranches.list(loan.id) do
      [] ->
        fees =
          if active?,
            do: loan.total_charges_due_at_disbursement_derived || Decimal.new("0.0"),
            else: zero

        {fees, fees}

      _tranches when not active? ->
        {zero, zero}

      tranches ->
        sum = fn list -> Enum.reduce(list, Decimal.new(0), &Decimal.add(&2, &1.principal)) end
        {paid, expected} = Enum.split_with(tranches, &(&1.disbursed_on != nil))
        left = Decimal.sub(loan.approved_principal, sum.(paid))

        {not_below_zero(left), not_below_zero(Decimal.sub(left, sum.(expected)))}
    end
  end

  defp not_below_zero(amount),
    do: if(Decimal.compare(amount, 0) == :lt, do: Decimal.new("0.0"), else: amount)

  defp delinquent(loan) do
    zero = 0
    today = ECBPlatform.BusinessDate.current()
    active? = loan.disbursedon_date != nil

    unpaid =
      if active?, do: Enum.reject(Loans.installments(loan.id), &(&1.completed == true)), else: []

    late = Enum.filter(unpaid, &(Date.compare(&1.due_date, today) == :lt))
    last = last_transaction(loan, ECBLoans.Loans.Repay.types())
    last_repayment = last_transaction(loan, [2])

    {available, available_with_expected} = available_disbursement(loan, active?, zero)

    %{
      "availableDisbursementAmount" => available,
      "availableDisbursementAmountWithOverApplied" => available_with_expected,
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
    |> then(
      &if(active?,
        do: Map.put(&1, "delinquencyPausePeriods", pause_periods(loan.id, today)),
        else: &1
      )
    )
    |> put(
      "nextPaymentDueDate",
      next_payment_due(unpaid, late, last || loan_written_off(loan), today)
    )
    |> arrears(late, today, loan.grace_on_arrears_ageing || 0, Actions.effective(loan.id))
    |> last_payment(last, last_repayment)
  end

  # the earliest unpaid installment's date, or the day of the last payment when that is later;
  # with nothing owed, the day of the last payment
  defp next_payment_due([], _late, nil, _today), do: nil

  defp next_payment_due([], _late, %{} = last, today),
    do: Enum.max([today, last.transaction_date], Date)

  defp next_payment_due([first | _], [], _last, _today), do: first.due_date
  defp next_payment_due([first | _], _late, nil, _today), do: first.due_date

  defp next_payment_due([first | _], _late, last, _today),
    do: Enum.max([first.due_date, last.transaction_date], Date)

  # the pauses of the loan's delinquency, with whether each is running
  defp pause_periods(loan_id, today) do
    for p <- Actions.periods(loan_id, today) do
      %{"active" => p.active, "pausePeriodStart" => p.start, "pausePeriodEnd" => p.end}
    end
  end

  defp arrears(map, [], _today, _grace, _pauses), do: map

  # the loan is delinquent once the grace on arrears ageing has gone by since the first due date, not counting the
  # days its delinquency was paused
  defp arrears(map, [first | _] = late, today, grace, pauses) do
    days = Date.diff(today, first.due_date)
    paused = Actions.paused_days(pauses, first.due_date, today)
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
      "delinquentDays" => max(days - paused - grace, 0),
      "delinquentDate" => Date.add(first.due_date, grace),
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

  # the latest transaction standing of one of the types
  defp last_transaction(loan, types) do
    loan.id
    |> Loans.transactions()
    |> Enum.filter(&(&1.transaction_type_enum in types and not &1.is_reversed))
    |> List.last()
  end

  # the last payment is the last of any repayment-like transaction, the last repayment the last plain repayment
  defp last_payment(map, payment, repayment) do
    map
    |> then(fn map ->
      if payment,
        do:
          Map.merge(map, %{
            "lastPaymentDate" => payment.transaction_date,
            "lastPaymentAmount" => payment.amount
          }),
        else: map
    end)
    |> then(fn map ->
      if repayment,
        do:
          Map.merge(map, %{
            "lastRepaymentDate" => repayment.transaction_date,
            "lastRepaymentAmount" => repayment.amount
          }),
        else: map
    end)
  end

  # --- the repayment schedule of a stored loan ---------------------------------------------------

  defp repayment_schedule(loan) do
    rows = Loans.installments(loan.id)
    today = ECBPlatform.BusinessDate.current()
    tranches = ECBLoans.Tranches.list(loan.id)

    {head, periods} =
      if tranches == [],
        do: plain_periods(loan, rows, today),
        else: tranche_periods(loan, rows, tranches, today)

    rows
    |> totals(loan)
    |> disbursed_total(tranches)
    |> Map.put("periods", head ++ periods)
    |> round_totals(loan.currency_digits)
  end

  defp plain_periods(loan, rows, today) do
    zero = Decimal.new("0.0")

    {periods, _balance} =
      Enum.map_reduce(rows, loan.principal_amount, fn r, balance ->
        balance = Decimal.sub(balance, r.principal || zero)
        {period(r, balance, today), balance}
      end)

    {[disbursement(loan, today)], periods}
  end

  # A loan paid out in tranches: a row for each tranche, those of the opening day first and the others just
  # before the installment they fall in, with the balance the installments leave counting every tranche so far.
  defp tranche_periods(loan, rows, tranches, today) do
    zero = Decimal.new("0.0")
    opening_date = loan.disbursedon_date || loan.expected_disbursedon_date
    tranches = Enum.map(tranches, &Map.put(&1, :date, &1.disbursed_on || &1.expected_date))
    {opening, later} = Enum.split_with(tranches, &(&1.date == opening_date))
    start = Enum.reduce(opening, zero, &Decimal.add(&2, &1.principal))

    {periods, _balance} =
      Enum.flat_map_reduce(rows, start, fn r, balance ->
        reached =
          Enum.filter(
            later,
            &(Date.compare(&1.date, r.from_date) == :gt and
                Date.compare(&1.date, r.due_date) != :gt)
          )

        balance = Enum.reduce(reached, balance, &Decimal.add(&2, &1.principal))
        balance = Decimal.sub(balance, r.principal || zero)
        {Enum.map(reached, &tranche_row(loan, &1, today)) ++ [period(r, balance, today)], balance}
      end)

    # the fees due when the loan is paid out are shown against the first tranche
    first =
      for {t, index} <- Enum.with_index(opening),
          do: tranche_row(loan, t, today, if(index == 0, do: at_disbursement(loan), else: zero))

    {first, periods}
  end

  defp disbursed_total(schedule, []), do: schedule

  defp disbursed_total(schedule, tranches) do
    total = Enum.reduce(tranches, Decimal.new(0), &Decimal.add(&2, &1.principal))
    Map.put(schedule, "totalPrincipalDisbursed", total)
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
    at_disbursement = loan.total_charges_due_at_disbursement_derived || zero
    fees = Decimal.add(sum.(& &1.fee_charges), at_disbursement)
    penalties = sum.(& &1.penalty_charges)
    # the fees due when the loan is paid out are paid with it
    paid_at_disbursement = if loan.disbursedon_date, do: at_disbursement, else: zero
    unpaid_at_disbursement = if loan.disbursedon_date, do: zero, else: at_disbursement

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
      "totalRepayment" => Decimal.add(sum.(&paid/1), paid_at_disbursement),
      "totalPaidInAdvance" => sum.(& &1.paid_in_advance),
      "totalPaidLate" => sum.(& &1.paid_late),
      "totalOutstanding" =>
        Enum.reduce(rows, unpaid_at_disbursement, fn r, acc ->
          Decimal.add(acc, outstanding(r))
        end),
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
    fees = loan.total_charges_due_at_disbursement_derived || Decimal.new("0.0")

    disbursement_row(
      loan.disbursedon_date || loan.expected_disbursedon_date,
      loan.principal_amount,
      fees,
      loan.disbursedon_date != nil,
      today
    )
  end

  defp at_disbursement(loan),
    do: loan.total_charges_due_at_disbursement_derived || Decimal.new("0.0")

  # a tranche of a loan paid out in parts
  defp tranche_row(_loan, t, today, fees \\ Decimal.new("0.0")),
    do: disbursement_row(t.date, t.principal, fees, t.disbursed_on != nil, today)

  defp disbursement_row(date, principal, fees, disbursed?, today) do
    %{
      "dueDate" => date,
      "principalDisbursed" => principal,
      "principalLoanBalanceOutstanding" => principal,
      "feeChargesDue" => fees,
      "totalOriginalDueForPeriod" => fees,
      "totalDueForPeriod" => fees,
      "totalActualCostOfLoanForPeriod" => fees,
      "downPaymentPeriod" => false
    }
    |> Map.merge(
      if disbursed?,
        do: %{"feeChargesPaid" => fees, "totalPaidForPeriod" => fees},
        else: %{"feeChargesOutstanding" => fees, "totalOutstandingForPeriod" => fees}
    )
    |> put("totalOverdue", if(not disbursed? and Date.compare(date, today) == :lt, do: fees))
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
      "totalActualCostOfLoanForPeriod" => interest |> Decimal.add(fees) |> Decimal.add(penalties),
      "totalInstallmentAmountForPeriod" => Decimal.add(principal, interest),
      "totalCredits" => zero,
      "totalAccruedInterest" => r.accrual_interest || zero,
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

  @doc false
  def only_fields(body, q, choosable \\ @choosable)

  def only_fields({:error, _} = error, _q, _choosable), do: error

  def only_fields(body, q, choosable) do
    case q["fields"] do
      fields when is_binary(fields) and fields != "" ->
        wanted = fields |> String.split(",") |> Enum.map(&String.trim/1)
        drop = MapSet.new(choosable -- wanted)
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

  @doc "`PUT /loans/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

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

  # the commands Fineract has for a loan transaction that are not built yet: refused, not taken for unknown ones
  @not_built_transactions ~w(refundByCash down-payment
                             reAge undo-reAge reAmortize undo-reAmortize capitalizedIncome buyDownFee)

  # `command=` of a transaction, and the action it runs
  @transaction_commands %{
    "repayment" => "REPAYMENT",
    "merchantIssuedRefund" => "MERCHANTISSUEDREFUND",
    "payoutRefund" => "PAYOUTREFUND",
    "goodwillCredit" => "GOODWILLCREDIT",
    "interestPaymentWaiver" => "INTERESTPAYMENTWAIVER",
    "chargeRefund" => "CHARGEREFUND",
    "recoverypayment" => "RECOVERYPAYMENT",
    "undowriteoff" => "UNDOWRITEOFF",
    "close-rescheduled" => "CLOSEASRESCHEDULED",
    "close" => "CLOSE",
    "charge-off" => "CHARGEOFF",
    "foreclosure" => "FORECLOSURE",
    "undo-charge-off" => "UNDOCHARGEOFF",
    "creditBalanceRefund" => "CREDITBALANCEREFUND",
    "waiveinterest" => "WAIVEINTERESTPORTION",
    "writeoff" => "WRITEOFF"
  }

  @doc "`POST /loans/:id/transactions?command=...`"
  def transaction_command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      command = conn.query_params["command"]

      cond do
        action = @transaction_commands[command] ->
          Write.execute(conn, @resource, action, id: id)

        command in @not_built_transactions ->
          Errors.render(conn, %ECBPlatform.Errors.DomainRuleViolation{
            code: "error.msg.loan.feature.not.supported.yet",
            message: "The loan transaction command #{command} is not supported yet by E-CoreBank",
            args: [command]
          })

        true ->
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
