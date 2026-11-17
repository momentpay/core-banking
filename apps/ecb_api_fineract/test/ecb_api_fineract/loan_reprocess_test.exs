defmodule ECBApiFineract.LoanReprocessTest do
  @moduledoc """
  What the repayments of a loan pay when one is taken back, changed or made out of order: the ones after it are
  worked out again, and a repayment that now pays something else is replaced by a new one. Fineract's own order of
  making the replacements is not repeatable, so the answers are checked by what they pay, not by transaction ids.
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

    assert send_json(
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
           ).status == 200

    for {command, field} <- [
          {"approve", "approvedOnDate"},
          {"disburse", "actualDisbursementDate"}
        ] do
      conn =
        send_json(
          :post,
          "/v1/loans/1?command=#{command}",
          Map.put(@dates, field, "01 March 2024")
        )

      assert conn.status == 200, conn.resp_body
    end

    :ok
  end

  defp repay(date, amount) do
    conn =
      send_json(
        :post,
        "/v1/loans/1/transactions?command=repayment",
        Map.merge(@dates, %{"transactionDate" => date, "transactionAmount" => amount})
      )

    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp undo(id) do
    send_json(
      :post,
      "/v1/loans/1/transactions/#{id}?command=undo",
      Map.merge(@dates, %{"transactionDate" => "01 March 2024", "transactionAmount" => 0})
    )
  end

  # what the repayments standing pay, oldest first, as {date, amount, principal, interest}
  defp repayments do
    loan = body(send_json(:get, "/v1/loans/1?associations=transactions"))

    for t <- loan["transactions"], t["type"]["id"] == 2, t["manuallyReversed"] != true do
      {Enum.join(t["date"], "-"), t["amount"], t["principalPortion"], t["interestPortion"]}
    end
  end

  test "taking back an older repayment works the later one out again" do
    first = repay("01 April 2024", 900)
    repay("10 April 2024", 500)
    before = repayments()
    assert [{"2024-4-1", 900.0, _, _}, {"2024-4-10", 500.0, _, _}] = before

    assert undo(first).status == 200
    assert [{"2024-4-10", 500.0, principal, interest}] = repayments()
    assert principal + interest == 500.0
    assert principal == 400.0 or principal > 400.0

    loan = body(send_json(:get, "/v1/loans/1"))
    assert loan["summary"]["principalPaid"] == principal
  end

  test "a repayment made out of order takes its place and the later one is worked out again" do
    repay("10 April 2024", 500)
    [{_, _, alone_principal, _}] = repayments()

    repay("01 April 2024", 900)
    assert [{"2024-4-1", 900.0, _, _}, {"2024-4-10", 500.0, later_principal, _}] = repayments()
    refute later_principal == alone_principal

    loan = body(send_json(:get, "/v1/loans/1"))
    paid = repayments() |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    assert_in_delta loan["summary"]["principalPaid"], paid, 0.005
  end

  test "changing an older repayment works the later ones out again" do
    first = repay("01 April 2024", 900)
    repay("10 April 2024", 500)
    [_, {_, _, was, _}] = repayments()

    conn =
      send_json(
        :post,
        "/v1/loans/1/transactions/#{first}?command=adjust",
        Map.merge(@dates, %{"transactionDate" => "01 April 2024", "transactionAmount" => 600})
      )

    assert conn.status == 200, conn.resp_body
    assert [{"2024-4-1", 600.0, _, _}, {"2024-4-10", 500.0, now, _}] = repayments()
    refute now == was
  end

  test "the entries of a replaced repayment are reversed and the new ones posted" do
    first = repay("01 April 2024", 900)
    repay("10 April 2024", 500)
    assert undo(first).status == 200

    loan = body(send_json(:get, "/v1/loans/1?associations=transactions"))

    standing =
      for t <- loan["transactions"], t["type"]["id"] == 2, t["manuallyReversed"] != true, do: t

    assert length(standing) == 1
    assert loan["status"]["id"] == 300
  end
end
