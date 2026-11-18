defmodule ECBApiFineract.LoanOfficerTest do
  @moduledoc """
  Giving a loan to another loan officer. The recorded scenario `loanofficer1` covers what Fineract answers; this
  covers the one case where it fails with HTTP 500 (a loan with an officer, no `fromLoanOfficerId` named), which
  E-CoreBank answers with a plain refusal.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

  defp send_json(method, path, body \\ nil),
    do: call(method, "/api" <> path, auth: admin(), body: body)

  setup do
    assert send_json(
             :post,
             "/v1/clients",
             Map.merge(@dates, %{
               "officeId" => 1,
               "legalFormId" => 1,
               "firstname" => "Ann",
               "lastname" => "Lee",
               "active" => true,
               "activationDate" => "01 January 2024"
             })
           ).status == 200

    for name <- ["Sam", "Tia"] do
      conn =
        send_json(
          :post,
          "/v1/staff",
          Map.merge(@dates, %{
            "officeId" => 1,
            "firstname" => name,
            "lastname" => "X",
            "isLoanOfficer" => true,
            "isActive" => true,
            "joiningDate" => "01 January 2024"
          })
        )

      assert conn.status == 200, conn.resp_body
    end

    product =
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

    assert product.status == 200, product.resp_body

    conn =
      send_json(
        :post,
        "/v1/loans",
        Map.merge(@dates, %{
          "clientId" => 1,
          "productId" => 1,
          "loanOfficerId" => 1,
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
      )

    assert conn.status == 200, conn.resp_body
    :ok
  end

  test "a loan with an officer cannot be given away without saying whose it is" do
    conn =
      send_json(
        :post,
        "/v1/loans/1?command=assignloanofficer",
        Map.merge(@dates, %{"toLoanOfficerId" => 2, "assignmentDate" => "01 March 2024"})
      )

    assert conn.status == 403
    [error] = body(conn)["errors"]
    assert error["userMessageGlobalisationCode"] == "error.msg.loan.not.assigned.to.loan.officer"
    assert body(send_json(:get, "/v1/loans/1"))["loanOfficerId"] == 1
  end

  test "naming the present officer lets the loan go to the other one, and then be taken away" do
    conn =
      send_json(
        :post,
        "/v1/loans/1?command=assignloanofficer",
        Map.merge(@dates, %{
          "fromLoanOfficerId" => 1,
          "toLoanOfficerId" => 2,
          "assignmentDate" => "01 March 2024"
        })
      )

    assert conn.status == 200, conn.resp_body
    assert body(send_json(:get, "/v1/loans/1"))["loanOfficerId"] == 2

    conn =
      send_json(
        :post,
        "/v1/loans/1?command=unassignloanofficer",
        Map.merge(@dates, %{"unassignedDate" => "01 March 2024"})
      )

    assert conn.status == 200, conn.resp_body
    refute Map.has_key?(body(send_json(:get, "/v1/loans/1")), "loanOfficerId")
  end
end
