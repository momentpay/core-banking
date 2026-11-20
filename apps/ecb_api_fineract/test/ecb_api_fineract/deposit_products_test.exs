defmodule ECBApiFineract.DepositProductsTest do
  @moduledoc """
  Fixed and recurring deposit products beyond the responses recorded from Fineract (those are in `ScenariosTest`):
  permissions, what the fixed deposit endpoints reach, the rules of a whole product and the charts that go with it.
  """
  use ECBApiFineract.ApiCase

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp ok(conn) do
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp code(conn), do: hd(body(conn)["errors"])["userMessageGlobalisationCode"]

  defp chart(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "Chart",
        "description" => "d",
        "fromDate" => "01 January 2024",
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en",
        "chartSlabs" => [
          %{
            "periodType" => 2,
            "fromPeriod" => 1,
            "toPeriod" => 12,
            "annualInterestRate" => 5,
            "currencyCode" => "USD"
          }
        ]
      },
      extra
    )
  end

  defp product(extra \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "name" => "Deposit #{n}",
        "shortName" => "D#{rem(n, 1000)}",
        "description" => "Term deposit",
        "currencyCode" => "USD",
        "digitsAfterDecimal" => 2,
        "nominalAnnualInterestRate" => 5,
        "interestCompoundingPeriodType" => 4,
        "interestPostingPeriodType" => 4,
        "interestCalculationType" => 1,
        "interestCalculationDaysInYearType" => 365,
        "minDepositTerm" => 6,
        "minDepositTermTypeId" => 2,
        "depositAmount" => 1000,
        "accountingRule" => 1,
        "locale" => "en",
        "charts" => [chart()]
      },
      extra
    )
  end

  defp create(kind, extra \\ %{}),
    do: send_json(:post, "/v1/#{kind}depositproducts", product(extra))

  defp created(kind, extra \\ %{}), do: kind |> create(extra) |> ok() |> Map.fetch!("resourceId")

  test "each action needs its own permission" do
    id = created("fixed")
    path = "/v1/fixeddepositproducts"

    assert send_json(:get, path, nil, make_user("p-none", [])).status == 403

    assert send_json(:get, path, nil, make_user("p-read", ["READ_FIXEDDEPOSITPRODUCT"])).status ==
             200

    assert send_json(
             :post,
             path,
             product(),
             make_user("p-no-create", ["READ_FIXEDDEPOSITPRODUCT"])
           ).status == 403

    assert send_json(
             :post,
             path,
             product(),
             make_user("p-create", ["CREATE_FIXEDDEPOSITPRODUCT"])
           ).status == 200

    assert send_json(
             :delete,
             "#{path}/#{id}",
             nil,
             make_user("p-no-delete", ["READ_FIXEDDEPOSITPRODUCT"])
           ).status ==
             403

    assert send_json(
             :delete,
             "#{path}/#{id}",
             nil,
             make_user("p-delete", ["DELETE_FIXEDDEPOSITPRODUCT"])
           ).status ==
             200
  end

  test "a product needs a name that is not used already, and the second try leaves the first alone" do
    first = product(%{"name" => "Twice", "shortName" => "TW1"})

    assert send_json(:post, "/v1/fixeddepositproducts", first)
           |> ok()
           |> Map.has_key?("resourceId")

    again = send_json(:post, "/v1/fixeddepositproducts", first)
    assert again.status == 403
    assert code(again) == "error.msg.savingsproduct.unknown.data.integrity.issue"
    assert length(ok(send_json(:get, "/v1/fixeddepositproducts"))) == 1
  end

  test "a product is read with its charts and the chart in force" do
    id = created("fixed")
    one = send_json(:get, "/v1/fixeddepositproducts/#{id}") |> ok()

    assert [%{"name" => "Chart", "chartSlabs" => [slab]}] = one["interestRateCharts"]
    assert slab["periodType"]["value"] == "Months"
    assert slab["annualInterestRate"] == 5
    assert one["activeChart"]["name"] == "Chart"
    assert one["minDepositTermType"]["value"] == "Months"
  end

  test "charts that overlap in dates are refused, once for each of the two" do
    charts = [
      chart(%{"name" => "A", "endDate" => "30 June 2024"}),
      chart(%{"name" => "B", "fromDate" => "01 June 2024", "endDate" => "30 December 2024"})
    ]

    conn = create("fixed", %{"charts" => charts})
    assert conn.status == 400

    assert Enum.map(body(conn)["errors"], & &1["userMessageGlobalisationCode"]) ==
             List.duplicate(
               "validation.msg.fixeddepositproduct.chart.overlapping.from.and.end.dates",
               2
             )
  end

  test "the minimum term may not be longer than the maximum, counting a month as 30 days" do
    conn =
      create("fixed", %{
        "minDepositTerm" => 12,
        "maxDepositTerm" => 6,
        "maxDepositTermTypeId" => 2
      })

    assert conn.status == 400
    assert code(conn) == "validation.msg.fixeddepositproduct.max.term.lessthan.min.term"

    assert create("fixed", %{
             "minDepositTerm" => 12,
             "minDepositTermTypeId" => 0,
             "maxDepositTerm" => 6,
             "maxDepositTermTypeId" => 2
           }).status ==
             200
  end

  test "interest cannot be posted more often than it compounds" do
    conn = create("fixed", %{"interestPostingPeriodType" => 1})
    assert conn.status == 400

    assert code(conn) ==
             "validation.msg.fixeddepositproduct.posting.period.type.is.less.than.compound.period.type"
  end

  test "a chart added to a product that is changed ends in an unhandled error, as in Fineract" do
    id = created("fixed")

    conn =
      send_json(:put, "/v1/fixeddepositproducts/#{id}", %{
        "charts" => [
          chart(%{
            "name" => "Second",
            "fromDate" => "01 January 2023",
            "endDate" => "31 December 2023"
          })
        ]
      })

    assert conn.status == 500
  end

  test "a chart is changed through its id, and a slab can be added to it" do
    id = created("fixed")

    [%{"id" => chart_id}] =
      send_json(:get, "/v1/fixeddepositproducts/#{id}")
      |> ok()
      |> Map.fetch!("interestRateCharts")

    dates = %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

    renamed =
      send_json(:put, "/v1/fixeddepositproducts/#{id}", %{
        "charts" => [Map.merge(dates, %{"id" => chart_id, "name" => "Renamed"})]
      })
      |> ok()

    assert renamed["changes"] == %{"chartSlabs" => %{"name" => "Renamed"}}

    extra = %{
      "periodType" => 2,
      "fromPeriod" => 13,
      "toPeriod" => 24,
      "annualInterestRate" => 6,
      "currencyCode" => "USD"
    }

    send_json(:put, "/v1/fixeddepositproducts/#{id}", %{
      "charts" => [Map.merge(dates, %{"id" => chart_id, "chartSlabs" => [extra]})]
    })
    |> ok()

    [one] =
      send_json(:get, "/v1/fixeddepositproducts/#{id}")
      |> ok()
      |> Map.fetch!("interestRateCharts")

    assert Enum.map(one["chartSlabs"], & &1["fromPeriod"]) == [1, 13]
    assert one["name"] == "Renamed"
  end

  test "the fixed deposit endpoints also reach recurring products, but not the other way round" do
    recurring = created("recurring")
    fixed = created("fixed")

    assert send_json(:get, "/v1/fixeddepositproducts/#{recurring}").status == 404
    assert send_json(:delete, "/v1/recurringdepositproducts/#{fixed}").status == 404
    assert send_json(:delete, "/v1/fixeddepositproducts/#{recurring}").status == 200
    assert send_json(:get, "/v1/recurringdepositproducts/#{recurring}").status == 404
  end

  test "a recurring product keeps the rules of its installments and changes them" do
    id = created("recurring", %{"isMandatoryDeposit" => true, "allowWithdrawal" => true})
    path = "/v1/recurringdepositproducts/#{id}"

    shown = send_json(:get, path) |> ok()
    assert shown["isMandatoryDeposit"] == true
    assert shown["allowWithdrawal"] == true
    assert shown["adjustAdvanceTowardsFuturePayments"] == false

    [%{"id" => chart_id}] = shown["interestRateCharts"]
    dates = %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

    changed =
      send_json(:put, path, %{
        "isMandatoryDeposit" => false,
        "charts" => [Map.put(dates, "id", chart_id)]
      })
      |> ok()

    assert changed["changes"] == %{"isMandatoryDeposit" => false}
    assert send_json(:get, path) |> ok() |> Map.fetch!("isMandatoryDeposit") == false
  end

  test "a product that keeps accounts in the books must name them, and is mapped to them" do
    conn = create("fixed", %{"accountingRule" => 2})
    assert conn.status == 400

    assert Enum.map(body(conn)["errors"], & &1["parameterName"]) == [
             "savingsControlAccountId",
             "savingsReferenceAccountId",
             "transfersInSuspenseAccountId",
             "interestOnSavingsAccountId",
             "incomeFromFeeAccountId",
             "incomeFromPenaltyAccountId"
           ]
  end
end
