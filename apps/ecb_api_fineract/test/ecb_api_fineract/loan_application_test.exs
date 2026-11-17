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

  describe "corrections" do
    defp repay(amount) do
      send_json(:post, "/v1/loans/1/transactions?command=repayment", %{
        "transactionDate" => "01 March 2024",
        "transactionAmount" => amount,
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en"
      })
    end

    defp paid_out do
      assert submit().status == 200

      assert send_json(:post, "/v1/loans/1?command=approve", %{
               "approvedOnDate" => "01 March 2024",
               "dateFormat" => "dd MMMM yyyy",
               "locale" => "en"
             }).status == 200

      assert send_json(:post, "/v1/loans/1?command=disburse", %{
               "actualDisbursementDate" => "01 March 2024",
               "dateFormat" => "dd MMMM yyyy",
               "locale" => "en"
             }).status == 200
    end

    test "an older repayment can be undone, and the later one is replaced by a new transaction" do
      paid_out()
      first = body(repay(100))["resourceId"]
      last = body(repay(50))["resourceId"]

      undo = fn tid ->
        send_json(:post, "/v1/loans/1/transactions/#{tid}?command=undo", %{
          "transactionDate" => "01 March 2024",
          "transactionAmount" => 0,
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })
      end

      # taking back the first one replaces the last with a new transaction, so the old id is gone
      assert undo.(first).status == 200
      assert undo.(last).status == 403
    end

    test "a loan with repayments cannot have its disbursal undone yet" do
      paid_out()
      assert repay(100).status == 200
      assert send_json(:post, "/v1/loans/1?command=undodisbursal", %{}).status == 403
    end
  end

  describe "accrual accounting" do
    defp accrual_product(rule) do
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
        assert send_json(:post, "/v1/glaccounts", %{
                 "name" => "Acc " <> code,
                 "glCode" => code,
                 "manualEntriesAllowed" => true,
                 "type" => type,
                 "usage" => 1
               }).status == 200
      end

      conn =
        send_json(:post, "/v1/loanproducts", %{
          "name" => "Accrual",
          "shortName" => "ACCR",
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
          "accountingRule" => rule,
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
          "incomeFromRecoveryAccountId" => 9,
          "locale" => "en"
        })

      assert conn.status == 200, conn.resp_body
      body(conn)["resourceId"]
    end

    defp loan_of(product_id) do
      assert submit(%{"productId" => product_id}).status == 200

      assert send_json(:post, "/v1/loans/1?command=approve", %{
               "approvedOnDate" => "01 March 2024",
               "dateFormat" => "dd MMMM yyyy",
               "locale" => "en"
             }).status == 200

      assert send_json(:post, "/v1/loans/1?command=disburse", %{
               "actualDisbursementDate" => "01 March 2024",
               "dateFormat" => "dd MMMM yyyy",
               "locale" => "en"
             }).status == 200
    end

    defp entries do
      conn = send_json(:get, "/v1/journalentries?loanId=1&orderBy=id&limit=100")

      for e <- body(conn)["pageItems"],
          do: {e["glAccountName"], e["entryType"]["value"], e["amount"], e["transactionId"]}
    end

    test "upfront accrual books the whole interest as income when the loan is paid out" do
      loan_of(accrual_product(4))

      assert entries() == [
               {"Acc A2", "DEBIT", 10_000.0, "L1"},
               {"Acc A1", "CREDIT", 10_000.0, "L1"},
               {"Acc A4", "DEBIT", 661.86, "L2"},
               {"Acc I1", "CREDIT", 661.86, "L2"}
             ]
    end

    test "periodic accrual books nothing for interest until the loan is closed, and takes it back when reopened" do
      loan_of(accrual_product(3))
      assert length(entries()) == 2

      pay = fn amount ->
        send_json(:post, "/v1/loans/1/transactions?command=repayment", %{
          "transactionDate" => "01 March 2024",
          "transactionAmount" => amount,
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })
      end

      paid = pay.(10_661.86)
      assert paid.status == 200
      closing = Enum.drop(entries(), 2)

      assert closing == [
               {"Acc A2", "CREDIT", 10_000.0, "L2"},
               {"Acc A4", "CREDIT", 661.86, "L2"},
               {"Acc A1", "DEBIT", 10_661.86, "L2"},
               {"Acc A4", "DEBIT", 661.86, "L3"},
               {"Acc I1", "CREDIT", 661.86, "L3"}
             ]

      undo =
        send_json(:post, "/v1/loans/1/transactions/#{body(paid)["resourceId"]}?command=undo", %{
          "transactionDate" => "01 March 2024",
          "transactionAmount" => 0,
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })

      assert undo.status == 200
      # the accrual is taken back first, then the repayment
      assert entries() |> Enum.drop(7) |> Enum.map(&elem(&1, 3)) == ["L3", "L3", "L2", "L2", "L2"]
    end
  end

  describe "template and modification" do
    test "the template needs a type, and someone signed in" do
      assert call(:get, "/api/v1/loans/template?templateType=individual").status == 401
      conn = send_json(:get, "/v1/loans/template?clientId=1")
      assert conn.status == 403

      assert [%{"userMessageGlobalisationCode" => "error.msg.loan.template.type.required"}] =
               body(conn)["errors"]
    end

    test "the template for a client and product carries the product's defaults and the choices" do
      conn = send_json(:get, "/v1/loans/template?templateType=individual&clientId=1&productId=1")
      assert conn.status == 200
      template = body(conn)
      assert template["clientName"] == "Ann Lee"
      assert template["principal"] == 10_000.0
      assert template["termFrequency"] == 12
      assert [%{"id" => 1}] = template["productOptions"]
      assert template["accountLinkingOptions"] == []
    end

    defp charge(attrs) do
      body =
        Map.merge(
          %{
            "name" => "A fee",
            "currencyCode" => "USD",
            "chargeAppliesTo" => 1,
            "chargeTimeType" => 1,
            "chargeCalculationType" => 1,
            "chargePaymentMode" => 0,
            "amount" => 50,
            "active" => true,
            "penalty" => false,
            "locale" => "en"
          },
          attrs
        )

      conn = send_json(:post, "/v1/charges", body)
      assert conn.status == 200, conn.resp_body
      body(conn)["resourceId"]
    end

    test "a charge that only applies when a loan is overdue is refused, not ignored" do
      id =
        charge(%{
          "name" => "Late",
          "chargeTimeType" => 9,
          "chargeCalculationType" => 2,
          "penalty" => true
        })

      conn = submit(%{"charges" => [%{"chargeId" => id, "amount" => 2}]})
      assert conn.status == 403

      assert [%{"userMessageGlobalisationCode" => "error.msg.loan.feature.not.supported.yet"}] =
               body(conn)["errors"]
    end

    test "a fee due at disbursement is taken from what is paid out, as a repayment at disbursement" do
      id = charge(%{"name" => "Processing"})
      assert submit(%{"charges" => [%{"chargeId" => id, "amount" => 50}]}).status == 200
      assert body(send_json(:get, "/v1/loans/1"))["netDisbursalAmount"] == 9950.0

      for command <- ["approve", "disburse"] do
        date = if command == "approve", do: "approvedOnDate", else: "actualDisbursementDate"

        assert send_json(:post, "/v1/loans/1?command=#{command}", %{
                 date => "01 March 2024",
                 "dateFormat" => "dd MMMM yyyy",
                 "locale" => "en"
               }).status == 200
      end

      loan = body(send_json(:get, "/v1/loans/1?associations=all"))

      assert [%{"type" => %{"id" => 1}}, %{"type" => %{"id" => 5}, "amount" => 50.0}, _] =
               loan["transactions"]

      assert [%{"amountPaid" => 50.0, "paid" => true}] = loan["charges"]
      assert loan["summary"]["feeChargesPaid"] == 50.0
    end

    test "a repayment pays the fee of an installment first, and taking it back restores the charge" do
      id = charge(%{"name" => "Monthly", "chargeTimeType" => 8})
      assert submit(%{"charges" => [%{"chargeId" => id, "amount" => 10}]}).status == 200

      for {command, date} <- [
            {"approve", "approvedOnDate"},
            {"disburse", "actualDisbursementDate"}
          ] do
        assert send_json(:post, "/v1/loans/1?command=#{command}", %{
                 date => "01 March 2024",
                 "dateFormat" => "dd MMMM yyyy",
                 "locale" => "en"
               }).status == 200
      end

      paid =
        send_json(:post, "/v1/loans/1/transactions?command=repayment", %{
          "transactionDate" => "01 March 2024",
          "transactionAmount" => 25,
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })

      assert paid.status == 200
      loan = body(send_json(:get, "/v1/loans/1?associations=all"))
      assert [%{"amountPaid" => 10.0, "amountOutstanding" => 110.0}] = loan["charges"]

      undone =
        send_json(:post, "/v1/loans/1/transactions/#{body(paid)["resourceId"]}?command=undo", %{
          "transactionDate" => "01 March 2024",
          "transactionAmount" => 0,
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })

      assert undone.status == 200
      loan = body(send_json(:get, "/v1/loans/1?associations=charges"))
      assert [%{"amountPaid" => +0.0, "amountOutstanding" => 120.0}] = loan["charges"]
    end

    test "changing an application works the schedule out again and says what changed" do
      assert submit().status == 200
      conn = send_json(:put, "/v1/loans/1", application(%{"principal" => 5000}))
      assert conn.status == 200
      assert %{"principal" => 5000, "locale" => "en", "charges" => []} = body(conn)["changes"]

      loan = send_json(:get, "/v1/loans/1?associations=repaymentSchedule")
      assert body(loan)["principal"] == 5000.0
      assert length(body(loan)["repaymentSchedule"]["periods"]) == 13
    end
  end
end
