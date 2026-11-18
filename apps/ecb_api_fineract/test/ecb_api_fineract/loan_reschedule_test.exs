defmodule ECBApiFineract.LoanRescheduleTest do
  @moduledoc """
  What E-CoreBank refuses to reschedule that Fineract does. The recorded scenarios `loanreschedule1` and
  `loanreschedule2` cover what Fineract answers; this covers what is refused with
  `error.msg.loan.feature.not.supported.yet`: a fixed installment amount for a span of dates, a loan with charges,
  and a loan that has been rescheduled already.
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

  defp request(extra) do
    Map.merge(
      %{
        "loanId" => 1,
        "rescheduleFromDate" => "01 April 2024",
        "submittedOnDate" => "01 March 2024",
        "rescheduleReasonId" => 1
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

    [%{"id" => code_id}] =
      Enum.filter(body(send_json(:get, "/v1/codes")), &(&1["name"] == "LoanRescheduleReason"))

    conn =
      send_json(:post, "/v1/codes/#{code_id}/codevalues", %{
        "name" => "Hardship",
        "position" => 1,
        "isActive" => true
      })

    assert conn.status == 200, conn.resp_body
    reason = body(conn)["subResourceId"]

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
    {:ok, reason: reason}
  end

  test "a fixed installment amount for a span of dates is refused", %{reason: reason} do
    conn =
      send_json(
        :post,
        "/v1/rescheduleloans",
        Map.merge(
          @dates,
          request(%{
            "rescheduleReasonId" => reason,
            "emi" => 700,
            "endDate" => "01 July 2024"
          })
        )
      )

    assert conn.status == 403
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"
    assert body(send_json(:get, "/v1/rescheduleloans")) == []
  end

  test "a loan that was rescheduled cannot be rescheduled again yet", %{reason: reason} do
    post!("/v1/rescheduleloans", request(%{"rescheduleReasonId" => reason, "extraTerms" => 2}))

    post!("/v1/rescheduleloans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})

    conn =
      send_json(
        :post,
        "/v1/rescheduleloans",
        Map.merge(
          @dates,
          request(%{
            "rescheduleReasonId" => reason,
            "rescheduleFromDate" => "01 May 2024",
            "extraTerms" => 1
          })
        )
      )

    assert conn.status == 403
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"
  end

  test "a request made while another is pending cannot be approved after it", %{reason: reason} do
    post!("/v1/rescheduleloans", request(%{"rescheduleReasonId" => reason, "extraTerms" => 2}))
    post!("/v1/rescheduleloans", request(%{"rescheduleReasonId" => reason, "extraTerms" => 1}))
    post!("/v1/rescheduleloans/1?command=approve", %{"approvedOnDate" => "01 March 2024"})

    conn =
      send_json(
        :post,
        "/v1/rescheduleloans/2?command=approve",
        Map.merge(@dates, %{"approvedOnDate" => "01 March 2024"})
      )

    assert conn.status == 403
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"
    assert [%{"id" => 2, "statusEnum" => %{"id" => 100}}] = pending()
  end

  test "a loan with a charge cannot be rescheduled yet", %{reason: reason} do
    post!("/v1/charges", %{
      "name" => "Fee",
      "currencyCode" => "USD",
      "chargeAppliesTo" => 1,
      "chargeTimeType" => 2,
      "chargeCalculationType" => 1,
      "chargePaymentMode" => 0,
      "amount" => 20,
      "active" => true,
      "penalty" => false
    })

    post!("/v1/loans/1/charges", %{"chargeId" => 1, "amount" => 20, "dueDate" => "10 April 2024"})

    conn =
      send_json(
        :post,
        "/v1/rescheduleloans",
        Map.merge(@dates, request(%{"rescheduleReasonId" => reason, "extraTerms" => 2}))
      )

    assert conn.status == 403
    assert code(conn) == "error.msg.loan.feature.not.supported.yet"
  end

  defp pending, do: body(send_json(:get, "/v1/rescheduleloans?command=pending"))
end
