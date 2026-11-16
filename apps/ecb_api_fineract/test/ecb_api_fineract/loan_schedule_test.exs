defmodule ECBApiFineract.LoanScheduleTest do
  @moduledoc """
  The loan schedule calculation beyond the responses recorded from Fineract (those are in `ScenariosTest`):
  who may ask, and what a request asks for that E-CoreBank does not support yet.
  """
  use ECBApiFineract.ApiCase

  defp send_json(method, path, body, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp setup_client_and_product do
    client =
      send_json(:post, "/v1/clients", %{
        "officeId" => 1,
        "legalFormId" => 1,
        "firstname" => "Ann",
        "lastname" => "Lee",
        "active" => true,
        "activationDate" => "01 January 2024",
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en"
      })

    assert client.status == 200, client.resp_body

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
  end

  defp request(extra \\ %{}) do
    Map.merge(
      %{
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
        "loanType" => "individual",
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en"
      },
      extra
    )
  end

  defp calculate(extra \\ %{}, auth \\ admin()),
    do: send_json(:post, "/v1/loans?command=calculateLoanSchedule", request(extra), auth)

  setup do
    setup_client_and_product()
    :ok
  end

  test "the first installment of a 12-month declining loan at 12 a year" do
    conn = calculate()
    assert conn.status == 200
    [_disbursement, first | _] = body(conn)["periods"]
    assert first["principalDue"] == 788.49
    assert first["interestDue"] == 100.0
    assert body(conn)["totalInterestCharged"] == 661.86
  end

  test "someone who is not signed in is refused" do
    conn = call(:post, "/api/v1/loans?command=calculateLoanSchedule", body: request())
    assert conn.status == 401
  end

  test "a request for something beyond the core term loan is refused, not ignored" do
    for extra <- [
          %{"charges" => [%{"chargeId" => 1, "amount" => 10}]},
          %{"disbursementData" => [%{"principal" => 100}]},
          %{"fixedEmiAmount" => 900},
          %{"isEqualAmortization" => true},
          %{"collateral" => [%{"clientCollateralId" => 1, "quantity" => 1}]},
          %{"interestChargedFromDate" => "15 March 2024"},
          %{"calendarId" => 1},
          %{"linkAccountId" => 1}
        ] do
      conn = calculate(extra)
      assert conn.status == 403, inspect(extra)

      assert [%{"userMessageGlobalisationCode" => "error.msg.loan.feature.not.supported.yet"}] =
               body(conn)["errors"]
    end
  end

  test "a group that does not exist is not found (groups are not built yet)" do
    conn = calculate(%{"loanType" => "group", "groupId" => 1, "clientId" => nil})
    assert conn.status == 404
  end

  test "a working week of fewer than seven days is refused until due dates can be moved" do
    changed =
      send_json(:put, "/v1/workingdays", %{
        "recurrence" => "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR",
        "repaymentRescheduleType" => 2,
        "extendTermForDailyRepayments" => false,
        "locale" => "en"
      })

    assert changed.status == 200, changed.resp_body

    try do
      conn = calculate()
      assert conn.status == 403

      assert [%{"userMessageGlobalisationCode" => "error.msg.loan.feature.not.supported.yet"}] =
               body(conn)["errors"]
    after
      send_json(:put, "/v1/workingdays", %{
        "recurrence" => "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR,SA,SU",
        "repaymentRescheduleType" => 2,
        "extendTermForDailyRepayments" => false,
        "locale" => "en"
      })
    end
  end
end
