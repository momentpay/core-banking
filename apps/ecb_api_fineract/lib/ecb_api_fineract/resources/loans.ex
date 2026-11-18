defmodule ECBApiFineract.Resources.Loans do
  @moduledoc """
  `/v1/loans`: loan accounts. So far the calculation of a repayment schedule
  (`POST /loans?command=calculateLoanSchedule`), which changes nothing and stores no command.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.{Charges, LoanAccounts}
  alias ECBLoans.Schedule
  alias ECBLoans.Schedule.Request
  alias ECBPlatform.Params

  @doc "`POST /loans`: with `?command=calculateLoanSchedule` the schedule the request would give."
  def create(conn) do
    case conn.query_params["command"] do
      "calculateLoanSchedule" -> calculate(conn)
      _ -> LoanAccounts.submit(conn)
    end
  end

  defp calculate(conn) do
    p = Params.parse!(conn.assigns[:raw_body])
    %{terms: terms, product: product} = Request.assemble!(p)
    schedule = Schedule.generate(terms)
    today = ECBPlatform.BusinessDate.current()
    Response.json(conn, 200, schedule_json(schedule, product, today))
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: Errors.render(conn, error),
        else: reraise(error, __STACKTRACE__)
  end

  # --- the schedule as Fineract shows it ------------------------------------------------------

  defp schedule_json(s, product, today) do
    zero = Decimal.new(0)

    %{
      "currency" => Charges.currency(product.currency),
      "loanTermInDays" => s.loan_term_in_days,
      "totalPrincipalDisbursed" => amount(s.principal),
      "totalPrincipalExpected" => amount(s.total_principal_expected),
      "totalPrincipalPaid" => zero,
      "totalInterestCharged" => amount(s.total_interest),
      "totalFeeChargesCharged" => amount(s.total_fees),
      "totalPenaltyChargesCharged" => amount(s.total_penalties),
      "totalRepaymentExpected" => amount(s.total_repayment_expected),
      "totalOutstanding" => zero,
      "totalCredits" => zero,
      "periods" => rows(s, today)
    }
  end

  # the periods in order: what is paid out when the loan starts, then each installment, with a row for every later
  # tranche just before the installment it falls in
  defp rows(%{disbursements: [_ | _] = tranches} = s, today) do
    opening = for %{before: 0} = t <- tranches, do: tranche(t, today)
    later = Enum.filter(tranches, &(&1.before > 0))

    installments =
      Enum.flat_map(s.periods, fn p ->
        for(t <- later, t.before == p.number, do: tranche(t, today)) ++ [period(p, today)]
      end)

    opening ++ installments
  end

  defp rows(s, today), do: [disbursement(s, today) | Enum.map(s.periods, &period(&1, today))]

  defp tranche(%{date: date, amount: money}, today) do
    zero = Decimal.new(0)

    %{
      "dueDate" => date,
      "principalDisbursed" => amount(money),
      "principalLoanBalanceOutstanding" => amount(money),
      "feeChargesDue" => zero,
      "feeChargesOutstanding" => zero,
      "totalOriginalDueForPeriod" => zero,
      "totalDueForPeriod" => zero,
      "totalOutstandingForPeriod" => zero,
      "totalOverdue" => overdue(date, today, zero),
      "totalActualCostOfLoanForPeriod" => zero,
      "downPaymentPeriod" => false
    }
  end

  defp disbursement(s, today) do
    zero = Decimal.new(0)

    fees =
      if s.disbursement_fees && ECBMoney.positive?(s.disbursement_fees),
        do: s.disbursement_fees_shown,
        else: zero

    %{
      "dueDate" => s.disbursement_date,
      "principalDisbursed" => amount(s.principal),
      "principalLoanBalanceOutstanding" => amount(s.principal),
      "feeChargesDue" => fees,
      "feeChargesOutstanding" => fees,
      "totalOriginalDueForPeriod" => fees,
      "totalDueForPeriod" => fees,
      "totalOutstandingForPeriod" => fees,
      "totalOverdue" => overdue(s.disbursement_date, today, fees),
      "totalActualCostOfLoanForPeriod" => fees,
      "downPaymentPeriod" => false
    }
  end

  # a due amount is overdue once its date is before the business date
  defp overdue(date, today, amount),
    do: if(Date.compare(date, today) == :lt, do: amount)

  defp period(p, today) do
    %{
      "period" => p.number,
      "fromDate" => p.from,
      "dueDate" => p.due,
      "daysInPeriod" => Date.diff(p.due, p.from),
      "principalOriginalDue" => amount(p.principal),
      "principalDue" => amount(p.principal),
      "principalOutstanding" => amount(p.principal),
      "principalLoanBalanceOutstanding" => amount(p.balance),
      "interestOriginalDue" => amount(p.interest),
      "interestDue" => amount(p.interest),
      "interestOutstanding" => amount(p.interest),
      "feeChargesDue" => amount(p.fees),
      "feeChargesOutstanding" => amount(p.fees),
      "penaltyChargesDue" => amount(p.penalties),
      "penaltyChargesOutstanding" => amount(p.penalties),
      "totalOriginalDueForPeriod" => amount(p.total),
      "totalDueForPeriod" => amount(p.total),
      "totalOutstandingForPeriod" => amount(p.total),
      "totalOverdue" => overdue(p.due, today, amount(p.total)),
      "totalActualCostOfLoanForPeriod" =>
        amount(p.interest |> ECBMoney.plus(p.fees) |> ECBMoney.plus(p.penalties)),
      "totalInstallmentAmountForPeriod" => amount(ECBMoney.plus(p.principal, p.interest)),
      "downPaymentPeriod" => false
    }
  end

  defp amount(%ECBMoney{amount: amount}), do: amount
end
