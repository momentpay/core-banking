defmodule ECBApiFineract.LoanGuarantorTest do
  @moduledoc """
  What guarantors do differently from Fineract. The recorded scenario `loanguarantor1` covers what Fineract
  answers; a guarantor that pledges a savings account is refused here, as savings accounts are not built yet.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

  defp send_json(method, path, body \\ nil),
    do: call(method, "/api" <> path, auth: admin(), body: body)

  setup do
    for {first, last} <- [{"Ann", "Lee"}, {"Bob", "Ray"}] do
      conn =
        send_json(
          :post,
          "/v1/clients",
          Map.merge(@dates, %{
            "officeId" => 1,
            "legalFormId" => 1,
            "firstname" => first,
            "lastname" => last,
            "active" => true,
            "activationDate" => "01 January 2024"
          })
        )

      assert conn.status == 200, conn.resp_body
    end

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

    conn =
      send_json(
        :post,
        "/v1/loans",
        Map.merge(@dates, %{
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
      )

    assert conn.status == 200, conn.resp_body
    :ok
  end

  test "a guarantor that pledges a savings account is refused" do
    conn =
      send_json(
        :post,
        "/v1/loans/1/guarantors",
        %{"guarantorTypeId" => 1, "entityId" => 2, "savingsId" => 1, "amount" => 100}
      )

    assert conn.status == 403
    [error] = body(conn)["errors"]
    assert error["userMessageGlobalisationCode"] == "error.msg.loan.feature.not.supported.yet"
    assert body(send_json(:get, "/v1/loans/1/guarantors")) == []
  end

  test "a customer can guarantee the loan and be made inactive" do
    conn =
      send_json(:post, "/v1/loans/1/guarantors", %{"guarantorTypeId" => 1, "entityId" => 2})

    assert conn.status == 200, conn.resp_body
    assert send_json(:delete, "/v1/loans/1/guarantors/1").status == 200
    assert [%{"status" => false}] = body(send_json(:get, "/v1/loans/1/guarantors"))
  end
end
