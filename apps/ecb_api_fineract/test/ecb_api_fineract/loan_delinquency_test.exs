defmodule ECBApiFineract.LoanDelinquencyTest do
  @moduledoc """
  Delinquency ranges, buckets and the classification of loans. The recorded scenarios `delinquency1` and
  `delinquency2` cover what Fineract answers; this covers what E-CoreBank refuses (buckets for working capital loans,
  installment-level delinquency) and the one rule taken from Fineract's code rather than recorded: a loan whose days of
  delinquency fall in none of the ranges of its bucket keeps the range it has.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

  defp send_json(method, path, body \\ nil),
    do: call(method, "/api" <> path, auth: admin(), body: body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp product(extra) do
    Map.merge(
      %{
        "name" => "Bucketed",
        "shortName" => "BUCK",
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
      },
      extra
    )
  end

  defp range(name, min, max) do
    body = %{"classification" => name, "minimumAgeDays" => min, "locale" => "en"}
    body = if max, do: Map.put(body, "maximumAgeDays", max), else: body
    conn = send_json(:post, "/v1/delinquency/ranges", body)
    assert conn.status == 200, conn.resp_body
    json(conn)["resourceId"]
  end

  defp business_date(date) do
    conn = send_json(:put, "/v1/configurations/name/enable-business-date", %{"enabled" => true})
    assert conn.status == 200, conn.resp_body

    conn =
      send_json(:post, "/v1/businessdate", %{
        "type" => "BUSINESS_DATE",
        "date" => date,
        "dateFormat" => "yyyy-MM-dd",
        "locale" => "en"
      })

    assert conn.status == 200, conn.resp_body
  end

  test "a bucket for working capital loans is refused once it is described in full" do
    early = range("Early", 1, 3)

    conn =
      send_json(:post, "/v1/delinquency/buckets", %{
        "name" => "Capital",
        "ranges" => [early],
        "bucketType" => "WORKING_CAPITAL",
        "minimumPaymentPeriodAndRule" => %{
          "frequency" => 1,
          "frequencyType" => "DAYS",
          "minimumPayment" => 5,
          "minimumPaymentType" => "PERCENTAGE"
        }
      })

    assert conn.status == 403

    assert [
             %{
               "userMessageGlobalisationCode" => "error.msg.delinquency.feature.not.supported.yet"
             }
           ] =
             json(conn)["errors"]

    assert json(send_json(:get, "/v1/delinquency/buckets")) == []
  end

  test "a product cannot ask for delinquency at the installment level" do
    early = range("Early", 1, 3)

    bucket =
      json(send_json(:post, "/v1/delinquency/buckets", %{"name" => "B", "ranges" => [early]}))[
        "resourceId"
      ]

    conn =
      send_json(
        :post,
        "/v1/loanproducts",
        product(%{"delinquencyBucketId" => bucket, "enableInstallmentLevelDelinquency" => true})
      )

    assert conn.status == 403

    assert json(conn)["errors"] |> hd() |> Map.fetch!("userMessageGlobalisationCode") ==
             "error.msg.loanproduct.feature.not.supported.yet"
  end

  test "a loan whose days fall in no range of the bucket is put in none" do
    early = range("Early", 1, 3)
    late = range("Late", 10, 20)

    bucket =
      json(
        send_json(:post, "/v1/delinquency/buckets", %{"name" => "Gap", "ranges" => [early, late]})
      )[
        "resourceId"
      ]

    assert send_json(:post, "/v1/loanproducts", product(%{"delinquencyBucketId" => bucket})).status ==
             200

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

    business_date("2024-03-01")

    application =
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

    assert send_json(:post, "/v1/loans", application).status == 200

    assert send_json(
             :post,
             "/v1/loans/1?command=approve",
             Map.merge(@dates, %{"approvedOnDate" => "01 March 2024"})
           ).status == 200

    assert send_json(
             :post,
             "/v1/loans/1?command=disburse",
             Map.merge(@dates, %{"actualDisbursementDate" => "01 March 2024"})
           ).status == 200

    # 6 days late: between the two ranges
    business_date("2024-04-07")
    assert send_json(:post, "/v1/jobs/35?command=executeJob", %{}).status == 202
    assert json(send_json(:get, "/v1/loans/1/delinquencytags")) == []

    # 12 days late: in the second
    business_date("2024-04-13")
    assert send_json(:post, "/v1/jobs/35?command=executeJob", %{}).status == 202

    assert [%{"delinquencyRange" => %{"classification" => "Late"}}] =
             json(send_json(:get, "/v1/loans/1/delinquencytags"))

    # 25 days late: past the last, which has a maximum; the loan keeps the range it has
    business_date("2024-04-26")
    assert send_json(:post, "/v1/jobs/35?command=executeJob", %{}).status == 202

    assert [%{"delinquencyRange" => %{"classification" => "Late"}} = tag] =
             json(send_json(:get, "/v1/loans/1/delinquencytags"))

    refute Map.has_key?(tag, "liftedOnDate")
  end
end
