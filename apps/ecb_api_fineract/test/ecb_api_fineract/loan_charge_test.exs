defmodule ECBApiFineract.LoanChargeTest do
  @moduledoc """
  The charges of a loan beyond what was recorded from Fineract (`ScenariosTest`, `loancharge6` and `loancharge7`):
  what a repayment pays when a charge is added after it was made, what is refused, and the reads.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

  defp send_json(method, path, body \\ nil),
    do: call(method, "/api" <> path, auth: admin(), body: body)

  defp post!(path, body) do
    conn = send_json(:post, path, body)
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp errors(conn), do: body(conn)["errors"] |> Enum.map(& &1["userMessageGlobalisationCode"])

  setup do
    post!(
      "/v1/clients",
      Map.merge(@dates, %{
        "officeId" => 1,
        "legalFormId" => 1,
        "firstname" => "Ann",
        "lastname" => "Lee",
        "active" => true,
        "activationDate" => "01 January 2024"
      })
    )

    for {name, time, calc, amount, penalty} <- [
          {"Installment fee", 8, 1, 10, false},
          {"Dated fee", 2, 1, 20, false},
          {"Late penalty", 2, 1, 5, true},
          {"Overdue", 9, 2, 2, true},
          {"Disbursement fee", 1, 1, 50, false}
        ] do
      post!("/v1/charges", %{
        "name" => name,
        "currencyCode" => "USD",
        "chargeAppliesTo" => 1,
        "chargeTimeType" => time,
        "chargeCalculationType" => calc,
        "chargePaymentMode" => 0,
        "amount" => amount,
        "active" => true,
        "penalty" => penalty,
        "locale" => "en"
      })
    end

    :ok
  end

  defp product(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "Basic",
        "shortName" => "BSIC",
        "currencyCode" => "USD",
        "digitsAfterDecimal" => 2,
        "principal" => 10_000,
        "numberOfRepayments" => 12,
        "repaymentEvery" => 1,
        "repaymentFrequencyType" => 2,
        "interestRatePerPeriod" => 12,
        "interestRateFrequencyType" => 3,
        "amortizationType" => 1,
        "interestType" => 0,
        "interestCalculationPeriodType" => 1,
        "transactionProcessingStrategyCode" => "mifos-standard-strategy",
        "daysInYearType" => 365,
        "daysInMonthType" => 30,
        "isInterestRecalculationEnabled" => false,
        "accountingRule" => 1,
        "locale" => "en"
      },
      extra
    )
  end

  defp loan(product_id \\ 1) do
    post!(
      "/v1/loans",
      Map.merge(@dates, %{
        "clientId" => 1,
        "productId" => product_id,
        "principal" => 10_000,
        "loanTermFrequency" => 12,
        "loanTermFrequencyType" => 2,
        "numberOfRepayments" => 12,
        "repaymentEvery" => 1,
        "repaymentFrequencyType" => 2,
        "interestRatePerPeriod" => 12,
        "interestRateFrequencyType" => 3,
        "amortizationType" => 1,
        "interestType" => 0,
        "interestCalculationPeriodType" => 1,
        "transactionProcessingStrategyCode" => "mifos-standard-strategy",
        "expectedDisbursementDate" => "01 March 2024",
        "submittedOnDate" => "01 March 2024",
        "loanType" => "individual"
      })
    )["loanId"]
  end

  defp approve_and_pay_out(id) do
    post!("/v1/loans/#{id}?command=approve", Map.put(@dates, "approvedOnDate", "01 March 2024"))

    post!(
      "/v1/loans/#{id}?command=disburse",
      Map.put(@dates, "actualDisbursementDate", "01 March 2024")
    )
  end

  defp active_loan do
    post!("/v1/loanproducts", product())
    id = loan()
    approve_and_pay_out(id)
    id
  end

  defp add(id, charge, amount, due \\ nil) do
    body = Map.merge(@dates, %{"chargeId" => charge, "amount" => amount})

    send_json(
      :post,
      "/v1/loans/#{id}/charges",
      if(due, do: Map.put(body, "dueDate", due), else: body)
    )
  end

  defp repay(id, date, amount) do
    post!(
      "/v1/loans/#{id}/transactions?command=repayment",
      Map.merge(@dates, %{"transactionDate" => date, "transactionAmount" => amount})
    )["resourceId"]
  end

  defp loan_with(id, associations),
    do: body(send_json(:get, "/v1/loans/#{id}?associations=#{associations}"))

  test "a charge added after a repayment was made is paid by that repayment" do
    id = active_loan()
    repay(id, "01 April 2024", 900)
    assert %{"resourceId" => 1} = body(add(id, 2, 20, "05 April 2024"))

    loan = loan_with(id, "all")

    [repayment] =
      for t <- loan["transactions"], t["type"]["id"] == 2, not t["manuallyReversed"], do: t

    # 888.49 pays the first installment; the rest goes to what the second asks of it, the fee first
    assert repayment["feeChargesPortion"] == 11.51
    assert loan["summary"]["feeChargesCharged"] == 20.0
    assert [%{"amountPaid" => 11.51, "amountOutstanding" => 8.49}] = loan["charges"]
  end

  test "a charge on a date after the last installment gets an installment of its own" do
    id = active_loan()
    assert add(id, 2, 40, "01 June 2030").status == 200
    periods = loan_with(id, "repaymentSchedule")["repaymentSchedule"]["periods"]
    assert length(periods) == 14
    last = List.last(periods)
    assert last["period"] == 13
    assert last["dueDate"] == [2030, 6, 1]
    assert last["feeChargesDue"] == 40.0
    assert last["principalDue"] == nil or last["principalDue"] == 0
  end

  test "an installment fee waived for one installment, once" do
    id = active_loan()
    assert %{"resourceId" => charge} = body(add(id, 1, 10))

    waive = fn ->
      send_json(
        :post,
        "/v1/loans/#{id}/charges/#{charge}?command=waive",
        Map.put(@dates, "installmentNumber", 3)
      )
    end

    first = waive.()
    assert first.status == 200
    assert %{"changes" => %{"amount" => 10.0}, "subResourceId" => _} = body(first)
    assert errors(waive.()) == ["error.msg.loan.charge.already.waived"]

    one = body(send_json(:get, "/v1/loans/#{id}/charges/#{charge}"))
    # what is still to be paid: eleven installments of twelve
    assert length(one["installmentChargeData"]) == 11
    assert one["amountWaived"] == 10.0
  end

  test "what is refused" do
    id = active_loan()

    # charges that are not taken yet, or that make no sense on a loan being repaid
    assert errors(add(id, 4, 2, "15 June 2024")) == [
             "error.msg.loanCharge.cannot.be.added.as.overdue.charge"
           ]

    assert errors(add(id, 5, 50)) == [
             "error.msg.charge.cannot.be.updated.no.pending.disbursements.in.loan"
           ]

    assert errors(add(id, 2, 20)) == ["error.msg.loanCharge.dueDate.cannot.be.blank"]

    assert errors(add(id, 2, 20, "01 January 2020")) ==
             ["error.msg.loanCharge.cannot.be.added.as.date.is.before.last.transaction.date"]

    assert send_json(:post, "/v1/loans/#{id}/charges", Map.put(@dates, "chargeId", 1)).status ==
             400

    assert add(id, 99, 1).status == 404

    # a charge has to exist, on this loan
    assert send_json(:get, "/v1/loans/#{id}/charges/7").status == 404
    other = loan()
    assert %{"resourceId" => charge} = body(add(id, 1, 10))
    assert send_json(:get, "/v1/loans/#{other}/charges/#{charge}").status == 404

    # paying by itself is for charges paid by account transfer; changing and deleting is for a loan awaiting approval
    pay =
      send_json(
        :post,
        "/v1/loans/#{id}/charges/#{charge}?command=pay",
        Map.merge(@dates, %{"transactionDate" => "01 April 2024"})
      )

    assert errors(pay) == ["error.msg.loan.charge.payment.mode.not.account.transfer"]

    assert errors(
             send_json(:put, "/v1/loans/#{id}/charges/#{charge}", %{
               "amount" => 12,
               "locale" => "en"
             })
           ) ==
             ["error.msg.loan.charge.associated.loan.not.in.submitted.and.pending.approval.stage"]

    assert errors(send_json(:delete, "/v1/loans/#{id}/charges/#{charge}")) ==
             ["error.msg.loan.charge.associated.loan.not.in.submitted.and.pending.approval.stage"]
  end

  test "a loan with upfront accrual accounting accrues a charge as it is added, and a waiver is a loss" do
    for {code, type} <- [
          {"A1", 1},
          {"A2", 1},
          {"A3", 1},
          {"A4", 1},
          {"A5", 1},
          {"A6", 1},
          {"L1", 2},
          {"I1", 4},
          {"I2", 4},
          {"I3", 4},
          {"X1", 5}
        ] do
      post!("/v1/glaccounts", %{
        "name" => "Acc " <> code,
        "glCode" => code,
        "manualEntriesAllowed" => true,
        "type" => type,
        "usage" => 1
      })
    end

    post!(
      "/v1/loanproducts",
      product(%{
        "accountingRule" => 4,
        "fundSourceAccountId" => 1,
        "loanPortfolioAccountId" => 2,
        "transfersInSuspenseAccountId" => 3,
        "receivableInterestAccountId" => 4,
        "receivableFeeAccountId" => 5,
        "receivablePenaltyAccountId" => 6,
        "overpaymentLiabilityAccountId" => 7,
        "interestOnLoanAccountId" => 8,
        "incomeFromFeeAccountId" => 9,
        "incomeFromPenaltyAccountId" => 10,
        "writeOffAccountId" => 11,
        "incomeFromRecoveryAccountId" => 9
      })
    )

    id = loan()
    approve_and_pay_out(id)
    assert %{"resourceId" => charge} = body(add(id, 2, 20, "15 June 2024"))

    # 20 earned and receivable at once, then written off by the waiver
    entries = fn ->
      for e <- body(send_json(:get, "/v1/journalentries?loanId=#{id}&orderBy=id"))["pageItems"],
          do: {e["glAccountCode"], e["entryType"]["value"], e["amount"]}
    end

    assert {"A5", "DEBIT", 20.0} in entries.()
    assert {"I2", "CREDIT", 20.0} in entries.()

    assert send_json(:post, "/v1/loans/#{id}/charges/#{charge}?command=waive", @dates).status ==
             200

    assert {"A5", "CREDIT", 20.0} in entries.()
    assert {"X1", "DEBIT", 20.0} in entries.()
  end

  test "a loan awaiting approval: charges are added, changed and deleted, and the schedule follows" do
    post!("/v1/loanproducts", product())
    id = loan()
    assert %{"resourceId" => charge} = body(add(id, 2, 20, "01 June 2024"))

    schedule = fn -> loan_with(id, "repaymentSchedule")["repaymentSchedule"] end
    assert schedule.()["totalFeeChargesCharged"] == 20.0

    changed =
      send_json(:put, "/v1/loans/#{id}/charges/#{charge}", %{"amount" => 35, "locale" => "en"})

    assert changed.status == 200, changed.resp_body
    assert body(changed)["changes"]["amount"] == 35.0
    assert schedule.()["totalFeeChargesCharged"] == 35.0

    assert [%{"id" => ^charge, "amount" => 35.0}] =
             body(send_json(:get, "/v1/loans/#{id}/charges"))

    # a charge on a date after the last installment waits for the loan to be paid out
    assert errors(add(id, 2, 9, "01 June 2030")) == ["error.msg.loan.feature.not.supported.yet"]

    assert send_json(:delete, "/v1/loans/#{id}/charges/#{charge}").status == 200
    assert body(send_json(:get, "/v1/loans/#{id}/charges")) == []

    assert schedule.()["totalFeeChargesCharged"] == 0.0 or
             schedule.()["totalFeeChargesCharged"] == 0
  end

  test "the charges a loan can take" do
    id = active_loan()
    template = body(send_json(:get, "/v1/loans/#{id}/charges/template"))

    assert Enum.map(template["chargeOptions"], & &1["name"]) == [
             "Dated fee",
             "Disbursement fee",
             "Installment fee",
             "Late penalty"
           ]
  end
end
