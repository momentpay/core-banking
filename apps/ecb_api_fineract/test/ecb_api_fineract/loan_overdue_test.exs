defmodule ECBApiFineract.LoanOverdueTest do
  @moduledoc """
  The job that adds penalties to overdue installments beyond what was recorded from Fineract (`ScenariosTest`,
  `loanoverdue1` to `loanoverdue4`): that it adds each penalty once, that it does what it can for the loans it
  can and fails naming the others, and what it keeps a loan from doing afterwards.
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

  defp business_date!(date) do
    post!("/v1/businessdate", %{
      "type" => "BUSINESS_DATE",
      "date" => date,
      "dateFormat" => "yyyy-MM-dd",
      "locale" => "en"
    })
  end

  defp run_job, do: send_json(:post, "/v1/jobs/12?command=executeJob", %{})

  setup do
    assert send_json(:put, "/v1/configurations/name/enable-business-date", %{"enabled" => true}).status ==
             200

    business_date!("2024-03-01")

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

    for {name, calc, amount, extra} <- [
          {"Flat", 1, 5, %{}},
          {"Weekly", 1, 3, %{"feeFrequency" => 1, "feeInterval" => 1}},
          {"Percent", 2, 1, %{}},
          {"Transfer", 1, 5, %{"chargePaymentMode" => 1}}
        ] do
      post!(
        "/v1/charges",
        Map.merge(
          %{
            "name" => name,
            "currencyCode" => "USD",
            "chargeAppliesTo" => 1,
            "chargeTimeType" => 9,
            "chargeCalculationType" => calc,
            "chargePaymentMode" => 0,
            "amount" => amount,
            "active" => true,
            "penalty" => true,
            "locale" => "en"
          },
          extra
        )
      )
    end

    for {name, short, charge} <- [
          {"Flat", "FLAT", 1},
          {"Weekly", "WEEK", 2},
          {"Percent", "PCT", 3},
          {"Transfer", "TRAN", 4}
        ] do
      post!("/v1/loanproducts", %{
        "name" => name,
        "shortName" => short,
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
        "charges" => [%{"id" => charge}],
        "locale" => "en"
      })
    end

    :ok
  end

  defp active_loan(product) do
    id =
      post!(
        "/v1/loans",
        Map.merge(@dates, %{
          "clientId" => 1,
          "productId" => product,
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

    post!("/v1/loans/#{id}?command=approve", Map.put(@dates, "approvedOnDate", "01 March 2024"))

    post!(
      "/v1/loans/#{id}?command=disburse",
      Map.put(@dates, "actualDisbursementDate", "01 March 2024")
    )

    id
  end

  defp charges(id), do: body(send_json(:get, "/v1/loans/#{id}/charges"))

  test "a penalty is added once for an installment, however often the job runs" do
    id = active_loan(1)
    business_date!("2024-04-10")

    assert run_job().status == 202
    assert run_job().status == 202

    assert [%{"dueDate" => [2024, 4, 1], "amount" => 5.0, "penalty" => true}] = charges(id)

    loan = body(send_json(:get, "/v1/loans/#{id}?associations=repaymentSchedule"))
    first = Enum.find(loan["repaymentSchedule"]["periods"], &(&1["period"] == 1))
    assert first["penaltyChargesDue"] == 5.0
  end

  test "a percentage is taken of what is outstanding of the installment when the penalty is added" do
    id = active_loan(3)
    business_date!("2024-04-02")

    post!(
      "/v1/loans/#{id}/transactions?command=repayment",
      Map.merge(@dates, %{"transactionDate" => "01 April 2024", "transactionAmount" => 400})
    )

    business_date!("2024-04-10")
    assert run_job().status == 202

    # 400 paid the interest (100) and 300 of the 788.49 of principal: 1% of the 488.49 left
    assert [%{"amount" => 4.88, "amountPercentageAppliedTo" => 488.49}] = charges(id)
  end

  test "a loan the job cannot add a penalty to does not stop the others, and the run fails naming it" do
    transfer = active_loan(4)
    flat = active_loan(1)

    business_date!("2024-04-10")
    conn = run_job()
    assert conn.status == 202

    assert charges(flat) != []
    assert charges(transfer) == []

    assert [%{"status" => "failed", "jobRunErrorMessage" => message}] =
             body(send_json(:get, "/v1/jobs/12/runhistory"))["pageItems"]

    assert message =~ "loan #{transfer}"
    assert message =~ "not supported yet"
  end

  test "a penalty that repeats goes on after the last installment, in an installment of its own" do
    weekly = active_loan(2)

    # a year and two months on, the weekly penalties are past the last installment (1 March 2025)
    business_date!("2025-05-01")
    assert run_job().status == 202

    loan = body(send_json(:get, "/v1/loans/#{weekly}?associations=repaymentSchedule"))
    periods = loan["repaymentSchedule"]["periods"]
    last = List.last(periods)

    assert last["period"] == 13
    assert last["penaltyChargesDue"] > 0
    assert last["principalDue"] in [nil, 0, 0.0]
    assert loan["actualNoTerm"] == 13
  end

  test "the disbursal of a loan with penalties for overdue installments is not undone yet" do
    id = active_loan(1)
    business_date!("2024-04-10")
    run_job()

    conn = send_json(:post, "/v1/loans/#{id}?command=undodisbursal", %{"note" => "oops"})
    assert conn.status == 403

    assert [%{"userMessageGlobalisationCode" => "error.msg.loan.feature.not.supported.yet"}] =
             body(conn)["errors"]
  end
end
