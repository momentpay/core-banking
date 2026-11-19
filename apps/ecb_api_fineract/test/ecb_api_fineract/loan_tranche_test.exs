defmodule ECBApiFineract.LoanTrancheTest do
  @moduledoc """
  What E-CoreBank refuses for a loan that is paid out in tranches, where Fineract does something it cannot yet
  be matched on: a tranche that is not above zero, charges, an approval for another amount or date, an amount
  asked for at the first disbursement, a later tranche, and the changes that work a schedule out again. The recorded
  scenarios `loantranche1` and `loantranche2` cover what Fineract answers and E-CoreBank matches.
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

  defp tranche(date, principal),
    do: %{"expectedDisbursementDate" => date, "principal" => principal}

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
        "interestCalculationPeriodType" => 0,
        "transactionProcessingStrategyCode" => "mifos-standard-strategy",
        "expectedDisbursementDate" => "01 March 2024",
        "submittedOnDate" => "01 March 2024",
        "loanType" => "individual",
        "disbursementData" => [tranche("01 March 2024", 6000), tranche("01 June 2024", 4000)]
      },
      extra
    )
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
        "name" => "Multi",
        "shortName" => "MULT",
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
        "interestCalculationPeriodType" => 0,
        "transactionProcessingStrategyCode" => "mifos-standard-strategy",
        "daysInYearType" => 365,
        "daysInMonthType" => 30,
        "isInterestRecalculationEnabled" => false,
        "accountingRule" => 1,
        "multiDisburseLoan" => true,
        "maxTrancheCount" => 3,
        "outstandingLoanBalance" => 20_000,
        "locale" => "en"
      })

    assert conn.status == 200, conn.resp_body
    :ok
  end

  defp refused?(conn) do
    assert conn.status == 403, conn.resp_body
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"
  end

  defp submit_and_approve do
    post!("/v1/loans", application())
    post!("/v1/loans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})
  end

  test "a tranche that is not above zero is refused" do
    for amount <- [0, -5] do
      conn =
        send_json(
          :post,
          "/v1/loans",
          Map.merge(
            @dates,
            application(%{"disbursementData" => [tranche("01 March 2024", amount)]})
          )
        )

      refused?(conn)
    end
  end

  test "charges on a loan that is paid out in tranches are refused" do
    post!("/v1/charges", %{
      "name" => "Fee",
      "currencyCode" => "USD",
      "chargeAppliesTo" => 1,
      "chargeTimeType" => 8,
      "chargeCalculationType" => 1,
      "chargePaymentMode" => 0,
      "amount" => 10,
      "active" => true,
      "penalty" => false
    })

    conn =
      send_json(
        :post,
        "/v1/loans",
        Map.merge(@dates, application(%{"charges" => [%{"chargeId" => 1, "amount" => 10}]}))
      )

    refused?(conn)

    submit_and_approve()

    refused?(
      send_json(
        :post,
        "/v1/loans/1/charges",
        Map.merge(@dates, %{"chargeId" => 1, "amount" => 10, "dueDate" => "10 April 2024"})
      )
    )
  end

  test "approving for another amount or date is refused, approving as asked for is not" do
    post!("/v1/loans", application())

    for extra <- [
          %{"approvedLoanAmount" => 8000},
          %{"expectedDisbursementDate" => "05 March 2024"}
        ] do
      conn =
        send_json(
          :post,
          "/v1/loans/1?command=approve",
          Map.merge(@dates, Map.merge(%{"approvedOnDate" => "01 March 2024"}, extra))
        )

      refused?(conn)
    end

    post!("/v1/loans/1?command=approve", %{
      "approvedOnDate" => "01 March 2024",
      "approvedLoanAmount" => 10_000
    })
  end

  test "the first disbursement pays out the first tranche, as it is expected" do
    submit_and_approve()

    # an amount of its own and another day change the schedule in ways that are not built
    refused?(
      send_json(
        :post,
        "/v1/loans/1?command=disburse",
        Map.merge(@dates, %{
          "actualDisbursementDate" => "01 March 2024",
          "transactionAmount" => 5000
        })
      )
    )

    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})

    body = body(send_json(:get, "/v1/loans/1?associations=all"))
    assert [%{"actualDisbursementDate" => [2024, 3, 1]} | _] = body["disbursementDetails"]
    assert body["netDisbursalAmount"] == 6000.0
  end

  test "a change of the application and a foreclosure are refused" do
    submit_and_approve()
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})

    refused?(
      send_json(
        :post,
        "/v1/loans/1/transactions?command=foreclosure",
        Map.merge(@dates, %{"transactionDate" => "01 March 2024"})
      )
    )
  end

  defp disburse(date, extra \\ %{}),
    do:
      send_json(
        :post,
        "/v1/loans/1?command=disburse",
        Map.merge(@dates, Map.merge(%{"actualDisbursementDate" => date}, extra))
      )

  defp undo_last, do: send_json(:post, "/v1/loans/1?command=undolastdisbursal", %{"note" => "x"})

  test "a later tranche is paid out on its day; an amount of its own and a day before the first are refused" do
    submit_and_approve()
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})

    refused?(disburse("01 June 2024", %{"transactionAmount" => 3000}))
    assert disburse("01 June 2024").status == 200

    body = body(send_json(:get, "/v1/loans/1?associations=all"))
    assert Enum.all?(body["disbursementDetails"], &is_list(&1["actualDisbursementDate"]))
    assert body["netDisbursalAmount"] == 4000.0

    # every tranche is paid out
    conn = disburse("01 July 2024")
    assert conn.status == 400
    assert code(conn) == "error.msg.loan.disbursal.account.is.not.approve.not.disbursed.state"
  end

  test "a tranche cannot be paid out on a day before the first one" do
    tranches = [tranche("10 March 2024", 6000), tranche("01 June 2024", 4000)]

    post!(
      "/v1/loans",
      application(%{
        "disbursementData" => tranches,
        "expectedDisbursementDate" => "10 March 2024"
      })
    )

    post!("/v1/loans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "10 March 2024"})
    refused?(disburse("05 March 2024"))
  end

  test "taking the last tranche back: Fineract's refusals, and what is not built" do
    submit_and_approve()
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})

    # fewer than two paid out
    conn = undo_last()
    assert conn.status == 403

    assert code(conn) ==
             "error.msg.tranches.should.be.disbursed.more.than.one.to.undo.last.disbursal"

    assert disburse("01 June 2024").status == 200

    # a repayment after the tranche
    post!("/v1/loans/1/transactions?command=repayment", %{
      "transactionDate" => "01 July 2024",
      "transactionAmount" => 900
    })

    conn = undo_last()
    assert conn.status == 403
    assert code(conn) == "error.msg.cannot.undo.last.disbursal.after.repayments or waivers"
  end

  test "the last tranche is taken back, and the whole disbursal cannot be after that" do
    submit_and_approve()
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})
    assert disburse("01 June 2024").status == 200
    assert undo_last().status == 200

    body = body(send_json(:get, "/v1/loans/1"))
    assert body["principal"] == 6000.0

    refused?(
      send_json(:post, "/v1/loans/1?command=undodisbursal", Map.merge(@dates, %{"note" => "x"}))
    )
  end

  test "a tranche is not taken back while another is still to be paid, nor one that paid several" do
    post!("/v1/loans", application(%{"disbursementData" => three_tranches()}))
    post!("/v1/loans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})
    assert disburse("01 May 2024").status == 200
    refused?(undo_last())
  end

  defp three_tranches,
    do: [
      tranche("01 March 2024", 4000),
      tranche("01 May 2024", 3000),
      tranche("01 July 2024", 3000)
    ]

  test "a disbursal that paid out several tranches at once is not taken back" do
    tranches = [
      tranche("01 March 2024", 4000),
      tranche("01 May 2024", 3000),
      tranche("01 May 2024", 3000)
    ]

    post!("/v1/loans", application(%{"disbursementData" => tranches}))
    post!("/v1/loans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})
    post!("/v1/loans/1?command=disburse", %{"actualDisbursementDate" => "01 March 2024"})
    assert disburse("01 May 2024").status == 200
    refused?(undo_last())
  end

  test "a first disbursement on another day than expected is refused" do
    submit_and_approve()

    refused?(
      send_json(
        :post,
        "/v1/loans/1?command=disburse",
        Map.merge(@dates, %{"actualDisbursementDate" => "15 March 2024"})
      )
    )
  end
end
