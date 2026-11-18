defmodule ECBApiFineract.LoanTransactionReadsTest do
  @moduledoc """
  What the transaction reads of a loan do differently from Fineract. The recorded scenarios `loantx2` (the list and
  the reads by external id) and `loantx3` (the templates) cover what Fineract answers.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

  defp send_json(method, path, body \\ nil),
    do: call(method, "/api" <> path, auth: admin(), body: body)

  defp post!(path, body) do
    conn = send_json(:post, path, Map.merge(@dates, body))
    assert conn.status == 200, conn.resp_body
    conn
  end

  setup do
    post!("/v1/clients", %{
      "officeId" => 1,
      "legalFormId" => 1,
      "firstname" => "Ann",
      "lastname" => "Lee",
      "active" => true,
      "activationDate" => "01 January 2024"
    })

    conn =
      send_json(:post, "/v1/loanproducts", %{
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
      })

    assert conn.status == 200, conn.resp_body

    post!("/v1/loans", %{
      "clientId" => 1,
      "productId" => 1,
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

    post!("/v1/loans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})
    :ok
  end

  test "the list is in order of id, and a page can be sorted by what is built" do
    conn = send_json(:get, "/v1/loans/1/transactions")
    assert conn.status == 200
    ids = for t <- body(conn)["content"], do: t["id"]
    assert ids == Enum.sort(ids)

    conn = send_json(:get, "/v1/loans/1/transactions?sort=amount,desc&size=1")
    assert [%{"amount" => amount}] = body(conn)["content"]
    assert amount == 10_000.0
    assert body(conn)["totalElements"] == 2
  end

  test "a sort property that is not built is answered like an unknown one (Fineract takes some of them)" do
    conn = send_json(:get, "/v1/loans/1/transactions?sort=loan")
    assert conn.status == 500
  end

  test "the templates that are not built are refused, the others are made" do
    conn = send_json(:get, "/v1/loans/1/transactions/template?command=foreclosure")
    assert conn.status == 403

    [error] = body(conn)["errors"]
    assert error["userMessageGlobalisationCode"] == "error.msg.loan.feature.not.supported.yet"

    conn = send_json(:get, "/v1/loans/1/transactions/template?command=prepayLoan")
    assert conn.status == 200
    assert body(conn)["type"]["value"] == "Repayment"
  end
end
