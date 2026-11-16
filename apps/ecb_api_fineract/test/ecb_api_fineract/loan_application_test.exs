defmodule ECBApiFineract.LoanApplicationTest do
  @moduledoc """
  Loan applications beyond the responses recorded from Fineract (those are in `ScenariosTest`): who may
  submit, approve and read, and what a submission asks for that E-CoreBank does not support yet.
  """
  use ECBApiFineract.ApiCase

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  setup do
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
    :ok
  end

  defp application(extra \\ %{}) do
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

  defp submit(extra \\ %{}, auth \\ admin()),
    do: send_json(:post, "/v1/loans", application(extra), auth)

  test "a submitted application is pending approval, with its schedule stored" do
    conn = submit()
    assert conn.status == 200, conn.resp_body
    assert %{"loanId" => 1, "clientId" => 1} = body(conn)

    loan = send_json(:get, "/v1/loans/1?associations=repaymentSchedule")
    assert body(loan)["status"]["id"] == 100
    assert body(loan)["accountNo"] == "000000001"
    assert length(body(loan)["repaymentSchedule"]["periods"]) == 13
    assert body(loan)["repaymentSchedule"]["totalInterestCharged"] == 661.86
  end

  test "someone who is not signed in may neither submit nor read" do
    assert call(:post, "/api/v1/loans", body: application()).status == 401
    assert call(:get, "/api/v1/loans/1").status == 401
  end

  test "an application for something beyond the core term loan is refused, not ignored" do
    for extra <- [
          %{"collateral" => [%{"clientCollateralId" => 1, "quantity" => 1}]},
          %{"calendarId" => 1}
        ] do
      conn = submit(extra)
      assert conn.status == 403, inspect(extra)

      assert [%{"userMessageGlobalisationCode" => "error.msg.loan.feature.not.supported.yet"}] =
               body(conn)["errors"]
    end
  end

  test "approving for less works the schedule out again, and undoing the approval restores it" do
    assert submit().status == 200

    approved =
      send_json(:post, "/v1/loans/1?command=approve", %{
        "approvedOnDate" => "01 March 2024",
        "approvedLoanAmount" => 5000,
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en"
      })

    assert approved.status == 200, approved.resp_body
    loan = send_json(:get, "/v1/loans/1?associations=repaymentSchedule")
    assert body(loan)["principal"] == 5000.0
    assert body(loan)["proposedPrincipal"] == 10_000.0
    assert body(loan)["repaymentSchedule"]["totalPrincipalExpected"] == 5000.0

    undone = send_json(:post, "/v1/loans/1?command=undoapproval", %{})
    assert undone.status == 200, undone.resp_body
    loan = send_json(:get, "/v1/loans/1?associations=repaymentSchedule")
    assert body(loan)["principal"] == 10_000.0
    assert body(loan)["repaymentSchedule"]["totalPrincipalExpected"] == 10_000.0
  end

  test "a loan that is no longer pending approval cannot be deleted" do
    assert submit().status == 200

    assert send_json(:post, "/v1/loans/1?command=approve", %{
             "approvedOnDate" => "01 March 2024",
             "dateFormat" => "dd MMMM yyyy",
             "locale" => "en"
           }).status == 200

    assert send_json(:delete, "/v1/loans/1").status == 403
  end

  test "an unknown command is a 400 and an unknown loan is a 404" do
    assert submit().status == 200
    assert send_json(:post, "/v1/loans/1?command=nonsense", %{}).status == 400
    assert send_json(:get, "/v1/loans/99").status == 404
  end

  describe "disbursement" do
    defp approve_loan do
      assert submit().status == 200

      assert send_json(:post, "/v1/loans/1?command=approve", %{
               "approvedOnDate" => "01 March 2024",
               "dateFormat" => "dd MMMM yyyy",
               "locale" => "en"
             }).status == 200
    end

    defp disburse(extra \\ %{}) do
      send_json(
        :post,
        "/v1/loans/1?command=disburse",
        Map.merge(
          %{
            "actualDisbursementDate" => "01 March 2024",
            "dateFormat" => "dd MMMM yyyy",
            "locale" => "en"
          },
          extra
        )
      )
    end

    test "something beyond a single payout is refused, not ignored" do
      approve_loan()

      for extra <- [
            %{"fixedEmiAmount" => 500},
            %{"linkAccountId" => 1},
            %{"postDatedChecks" => [%{}]}
          ] do
        conn = disburse(extra)
        assert conn.status == 403, inspect(extra)

        assert [%{"userMessageGlobalisationCode" => "error.msg.loan.feature.not.supported.yet"}] =
                 body(conn)["errors"]
      end
    end

    test "a loan can only be paid out once, and it is then active with its transactions" do
      approve_loan()
      assert disburse().status == 200
      assert disburse().status == 400

      loan = send_json(:get, "/v1/loans/1?associations=transactions")
      assert body(loan)["status"]["id"] == 300
      assert body(loan)["summary"]["principalOutstanding"] == 10_000.0
      assert Enum.map(body(loan)["transactions"], & &1["type"]["id"]) == [1, 10]
    end
  end
end
