defmodule ECBApiFineract.LoanChargeOffTest do
  @moduledoc """
  What a charged-off loan refuses. The recorded scenario `loanchargeoff1` covers what Fineract answers; this covers
  what it does that E-CoreBank does not do yet (it works the charge-off out again, or accrues again what it has
  adjusted), which is refused with `error.msg.loan.feature.not.supported.yet`.
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

  defp code(conn), do: hd(body(conn)["errors"])["userMessageGlobalisationCode"]

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

    post!("/v1/loans/1/transactions?command=repayment", %{
      "transactionDate" => "01 April 2024",
      "transactionAmount" => 1000
    })

    post!("/v1/loans/1/transactions?command=charge-off", %{"transactionDate" => "15 April 2024"})
    :ok
  end

  test "a repayment dated before the charge-off is refused, one after it is taken" do
    conn =
      send_json(
        :post,
        "/v1/loans/1/transactions?command=repayment",
        Map.merge(@dates, %{"transactionDate" => "10 April 2024", "transactionAmount" => 50})
      )

    assert conn.status == 403
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"

    post!("/v1/loans/1/transactions?command=repayment", %{
      "transactionDate" => "20 April 2024",
      "transactionAmount" => 50
    })
  end

  test "a transaction made after the charge-off cannot be undone on a loan without accounting" do
    conn =
      post!("/v1/loans/1/transactions?command=repayment", %{
        "transactionDate" => "20 April 2024",
        "transactionAmount" => 50
      })

    tid = body(conn)["resourceId"]

    conn =
      send_json(
        :post,
        "/v1/loans/1/transactions/#{tid}?command=undo",
        Map.merge(@dates, %{"transactionDate" => "20 April 2024", "transactionAmount" => 0})
      )

    assert conn.status == 403
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"
  end

  test "a loan charged off is not written off, closed or given a charge" do
    for {path, body} <- [
          {"/v1/loans/1/transactions?command=writeoff", %{"transactionDate" => "20 April 2024"}},
          {"/v1/loans/1/transactions?command=close", %{"transactionDate" => "20 April 2024"}},
          {"/v1/loans/1/transactions?command=close-rescheduled",
           %{"transactionDate" => "20 April 2024"}}
        ] do
      conn = send_json(:post, path, Map.merge(@dates, body))
      assert conn.status == 403, path
      assert code(conn) == "error.msg.loan.feature.not.supported.yet", path
    end
  end

  test "taking the charge-off back lets the loan be written off again" do
    conn = send_json(:post, "/v1/loans/1/transactions?command=undo-charge-off", %{})
    assert conn.status == 200, conn.resp_body
    assert body(send_json(:get, "/v1/loans/1"))["chargedOff"] == false

    post!("/v1/loans/1/transactions?command=writeoff", %{"transactionDate" => "20 April 2024"})
  end
end
