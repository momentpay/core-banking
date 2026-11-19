defmodule ECBApiFineract.Resources.LoanTransactionTemplate do
  @moduledoc """
  `GET /loans/{id}/transactions/template?command=...`: what a form for a loan transaction starts from, as
  Fineract's `LoanTransactionsApiResource.retrieveTransactionTemplate` answers it.

  Built: `repayment` (the next installment due), `prepayLoan`, `merchantIssuedRefund`, `payoutRefund` and
  `goodwillCredit` and `interestPaymentWaiver` (all that is outstanding), `waiveinterest`, `writeoff`, `close`,
  `close-rescheduled`, `recoverypayment`, `creditBalanceRefund`, `charge-off` and `foreclosure`. The other commands Fineract has are refused as not
  supported yet; any other command is `The query parameter command has an unsupported value`.

  A few oddities are kept: the template of a credit balance refund is dated with the real clock, not the business
  date, and `prepayLoan` is always as of the business date whatever `transactionDate` it is given.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{LoanAccounts, LoanProducts, PaymentTypes, Read, Write}
  alias ECBLoans.Loans
  alias ECBOrg.PaymentTypes, as: OrgPaymentTypes
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Errors.{DomainRuleViolation, ServerError, UnrecognizedQueryParameter}

  @resource "LOAN"

  @prepay %{
    "prepayLoan" => 2,
    "merchantIssuedRefund" => 21,
    "payoutRefund" => 22,
    "goodwillCredit" => 23,
    "interestPaymentWaiver" => 31
  }

  @built ~w(repayment recoverypayment creditBalanceRefund waiveinterest writeoff close close-rescheduled
            charge-off foreclosure prepayLoan merchantIssuedRefund payoutRefund goodwillCredit interestPaymentWaiver)

  @not_built ~w(refundbycash refundbytransfer downPayment contractTermination
                loanWithdrawal reAge reAmortize capitalizedIncome capitalizedIncomeAdjustment buyDownFee
                buyDownFeeAdjustment interest-refund disburse disburseToSavings)

  @doc "`GET /loans/:id/transactions/template`"
  def show(conn, raw_id) do
    case Write.path_id(raw_id) do
      {:ok, id} -> answer(conn, fn -> Loans.get(id) || id end)
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "`GET /loans/external-id/:external_id/transactions/template`"
  def show_by_external_id(conn, external_id) do
    answer(conn, fn ->
      Loans.get_by_external_id(external_id) || {:external, external_id}
    end)
  end

  defp answer(conn, find) do
    command = conn.query_params["command"]

    cond do
      command in @built ->
        Read.respond(conn, @resource, fn -> body(find.(), command, conn.query_params) end)

      command in @not_built ->
        Errors.render(conn, %DomainRuleViolation{
          code: "error.msg.loan.feature.not.supported.yet",
          message: "The loan transaction template #{command} is not supported yet by E-CoreBank",
          args: [command]
        })

      true ->
        Errors.render(conn, %UnrecognizedQueryParameter{
          name: "command",
          value: command,
          allowed: []
        })
    end
  end

  # what is sent for `command`; a loan that is not there is a 500 for the repayment template (its query finds
  # nothing), a not-found for the others
  defp body(%{id: _} = loan, "foreclosure", query) do
    on = foreclosure_date(query)

    payable =
      loan
      |> ECBLoans.Loans.Foreclosure.template(on)
      |> Map.new(fn {part, amount} -> {part, Decimal.add(amount, Decimal.new("0.0"))} end)

    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(2),
      "date" => BusinessDate.current(),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => total(payable),
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "principalPortion" => payable.principal,
      "interestPortion" => payable.interest,
      "feeChargesPortion" => payable.fees,
      "penaltyChargesPortion" => payable.penalties,
      "outstandingLoanBalance" => payable.principal,
      "manuallyReversed" => false,
      "paymentTypeOptions" => payment_types()
    }
    |> external(loan)
    |> LoanAccounts.only_fields(query, choosable())
  end

  defp body(%{id: _} = loan, command, query),
    do:
      command
      |> build(loan, Loans.installments(loan.id))
      |> LoanAccounts.only_fields(query, choosable())

  defp body(id, "repayment", _query) when is_integer(id), do: {:error, %ServerError{}}
  defp body(id, _command, _query) when is_integer(id), do: {:error, Loans.not_found(id)}
  defp body({:external, ext}, _command, _query), do: {:error, Loans.not_found_by_external_id(ext)}

  # the day the foreclosure is asked about: the business date unless the request names one
  defp foreclosure_date(%{"transactionDate" => _} = query) do
    query
    |> Map.take(["transactionDate", "dateFormat", "locale"])
    |> Jason.encode!()
    |> ECBPlatform.Params.parse!()
    |> ECBPlatform.Params.date("transactionDate")
  end

  defp foreclosure_date(_query), do: BusinessDate.current()

  # the names `fields=` can take out of a template: the same Fineract's transaction serializer knows
  defp choosable,
    do:
      ~w(id type date currency amount externalId reversalExternalId reversedOnDate classification
         numberOfFutureInstallments numberOfPastInstallments nextInstallmentDueDate calculatedStartDate)

  # --- the commands --------------------------------------------------------------------------------

  defp build("repayment", loan, rows) do
    row = Enum.find(rows, &(Decimal.compare(total_due(&1), 0) == :gt)) || List.first(rows)
    last = last_repayment_date(loan.id)

    principal = due(row, :principal, [:principal_completed, :principal_writtenoff])
    interest = due(row, :interest, [:interest_completed, :interest_waived, :interest_writtenoff])

    fees =
      due(row, :fee_charges, [
        :fee_charges_completed,
        :fee_charges_writtenoff,
        :fee_charges_waived
      ])

    penalties =
      due(row, :penalty_charges, [
        :penalty_charges_completed,
        :penalty_charges_writtenoff,
        :penalty_charges_waived
      ])

    %{
      "type" => LoanAccounts.transaction_type_json(2),
      "date" => later(last, row.due_date),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => principal |> add(interest) |> add(fees) |> add(penalties),
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "principalPortion" => principal,
      "interestPortion" => interest,
      "feeChargesPortion" => fees,
      "penaltyChargesPortion" => penalties,
      "manuallyReversed" => false,
      "paymentTypeOptions" => payment_types()
    }
  end

  defp build(command, loan, rows) when is_map_key(@prepay, command) do
    sums = sums(rows)

    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(Map.fetch!(@prepay, command)),
      "date" => BusinessDate.current(),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => total(sums),
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "principalPortion" => sums.principal,
      "interestPortion" => sums.interest,
      "feeChargesPortion" => sums.fees,
      "penaltyChargesPortion" => sums.penalties,
      "outstandingLoanBalance" => sums.principal,
      "manuallyReversed" => false,
      "paymentTypeOptions" => payment_types()
    }
    |> external(loan)
  end

  defp build("waiveinterest", loan, rows) do
    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(4),
      "date" => BusinessDate.current(),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => sums(rows).interest,
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "manuallyReversed" => false
    }
    |> external(loan)
  end

  defp build("writeoff", loan, rows) do
    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(6),
      "date" => BusinessDate.current(),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => if(summary?(loan), do: total(sums(rows))),
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "manuallyReversed" => false,
      "writeOffReasonOptions" => LoanProducts.code_values("WriteOffReasons")
    }
    |> external(loan)
  end

  defp build(command, _loan, _rows) when command in ["close", "close-rescheduled"] do
    %{
      "type" => LoanAccounts.transaction_type_json(6),
      "date" => BusinessDate.current(),
      "manuallyReversed" => false
    }
  end

  defp build("recoverypayment", loan, _rows) do
    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(8),
      "amount" => loan.total_writtenoff_derived || Decimal.new("0.0"),
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "manuallyReversed" => false,
      "paymentTypeOptions" => payment_types()
    }
    |> external(loan)
  end

  defp build("creditBalanceRefund", loan, _rows) do
    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(20),
      "date" => Date.utc_today(),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => loan.total_overpaid_derived,
      "manuallyReversed" => false
    }
    |> external(loan)
  end

  defp build("charge-off", loan, rows) do
    sums = sums(rows)

    %{
      "loanId" => loan.id,
      "type" => LoanAccounts.transaction_type_json(27),
      "date" => BusinessDate.current(),
      "currency" => LoanAccounts.currency_json(loan),
      "amount" => if(summary?(loan), do: total(sums)),
      "netDisbursalAmount" => loan.net_disbursal_amount,
      "principalPortion" => if(summary?(loan), do: sums.principal),
      "interestPortion" => if(summary?(loan), do: sums.interest),
      "feeChargesPortion" => if(summary?(loan), do: sums.fees),
      "penaltyChargesPortion" => if(summary?(loan), do: sums.penalties),
      "manuallyReversed" => false,
      "chargeOffReasonOptions" => LoanProducts.code_values("ChargeOffReasons")
    }
    |> external(loan)
  end

  # a loan not yet paid out has no summary, so the templates that take their amounts from it show none
  defp summary?(loan), do: loan.loan_status_id not in [100, 200]

  defp external(map, %{external_id: nil}), do: map
  defp external(map, %{external_id: ext}), do: Map.put(map, "externalLoanId", ext)

  defp payment_types, do: Enum.map(OrgPaymentTypes.list(), &PaymentTypes.serialize/1)

  # --- the sums ------------------------------------------------------------------------------------

  # the greater of the day of the last repayment and the installment's due day
  defp later(nil, due), do: due
  defp later(last, due), do: if(Date.compare(last, due) == :gt, do: last, else: due)

  defp last_repayment_date(loan_id) do
    loan_id
    |> Loans.transactions()
    |> Enum.filter(&(&1.transaction_type_enum in [2, 28] and not &1.is_reversed))
    |> Enum.map(& &1.transaction_date)
    |> Enum.max(Date, fn -> nil end)
  end

  defp total_due(row) do
    [
      due(row, :principal, [:principal_completed, :principal_writtenoff]),
      due(row, :interest, [:interest_completed, :interest_waived, :interest_writtenoff]),
      due(row, :fee_charges, [
        :fee_charges_completed,
        :fee_charges_writtenoff,
        :fee_charges_waived
      ]),
      due(row, :penalty_charges, [
        :penalty_charges_completed,
        :penalty_charges_writtenoff,
        :penalty_charges_waived
      ])
    ]
    |> Enum.reduce(Decimal.new(0), &add/2)
  end

  # what an installment still asks of one kind; with nothing asked and nothing taken off it is a plain 0
  defp due(row, asked, taken) do
    parts = [Map.fetch!(row, asked) | Enum.map(taken, &Map.fetch!(row, &1))]

    if Enum.all?(parts, &is_nil/1) do
      0
    else
      Enum.reduce(taken, zero(Map.fetch!(row, asked)), fn key, left ->
        Decimal.sub(left, zero(Map.fetch!(row, key)))
      end)
    end
  end

  defp sums(rows) do
    sum = fn asked, taken ->
      rows
      |> Enum.map(&decimal_due(&1, asked, taken))
      |> Enum.reduce(Decimal.new("0.0"), &Decimal.add/2)
    end

    %{
      principal: sum.(:principal, [:principal_completed, :principal_writtenoff]),
      interest: sum.(:interest, [:interest_completed, :interest_waived, :interest_writtenoff]),
      fees:
        sum.(:fee_charges, [:fee_charges_completed, :fee_charges_writtenoff, :fee_charges_waived]),
      penalties:
        sum.(:penalty_charges, [
          :penalty_charges_completed,
          :penalty_charges_writtenoff,
          :penalty_charges_waived
        ])
    }
  end

  defp decimal_due(row, asked, taken) do
    case due(row, asked, taken) do
      0 -> Decimal.new(0)
      d -> d
    end
  end

  defp total(%{principal: p, interest: i, fees: f, penalties: n}),
    do: p |> add(i) |> add(f) |> add(n)

  defp add(a, b), do: Decimal.add(a, b)
  defp zero(nil), do: Decimal.new(0)
  defp zero(d), do: d
end
