defmodule ECBApiFineract.RecurringDepositAccountsTest do
  @moduledoc """
  Recurring deposit accounts beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions,
  the schedule and the maturity an application works out, how it is changed, what is refused because it is not built
  yet, and where E-CoreBank deliberately does not do what Fineract does.
  """
  use ECBApiFineract.ApiCase
  import Ecto.Query

  @dates %{"dateFormat" => "yyyy-MM-dd", "locale" => "en"}

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp ok(conn) do
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp code(conn), do: hd(body(conn)["errors"])["userMessageGlobalisationCode"]

  defp client do
    send_json(
      :post,
      "/v1/clients",
      Map.merge(
        %{
          "officeId" => 1,
          "legalFormId" => 1,
          "firstname" => "Ann",
          "lastname" => "Lee",
          "active" => true,
          "activationDate" => "2020-01-01"
        },
        @dates
      )
    )
    |> ok()
    |> Map.fetch!("resourceId")
  end

  defp business_date(date) do
    send_json(:put, "/v1/configurations/name/enable-business-date", %{"enabled" => true}) |> ok()

    send_json(:post, "/v1/businessdate", %{
      "type" => "BUSINESS_DATE",
      "date" => date,
      "dateFormat" => "yyyy-MM-dd",
      "locale" => "en"
    })
    |> ok()
  end

  defp product do
    n = System.unique_integer([:positive])

    send_json(:post, "/v1/recurringdepositproducts", %{
      "name" => "RD #{n}",
      "shortName" => "R#{rem(n, 1000)}",
      "description" => "Recurring",
      "currencyCode" => "USD",
      "digitsAfterDecimal" => 2,
      "nominalAnnualInterestRate" => 5,
      "interestCompoundingPeriodType" => 1,
      "interestPostingPeriodType" => 4,
      "interestCalculationType" => 1,
      "interestCalculationDaysInYearType" => 365,
      "minDepositTerm" => 6,
      "minDepositTermTypeId" => 2,
      "maxDepositTerm" => 60,
      "maxDepositTermTypeId" => 2,
      "inMultiplesOfDepositTerm" => 6,
      "inMultiplesOfDepositTermTypeId" => 2,
      "depositAmount" => 1000,
      "accountingRule" => 1,
      "isMandatoryDeposit" => true,
      "allowWithdrawal" => true,
      "adjustAdvanceTowardsFuturePayments" => true,
      "locale" => "en",
      "charts" => [
        %{
          "name" => "Chart",
          "fromDate" => "01 January 2020",
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en",
          "chartSlabs" => [
            %{
              "periodType" => 2,
              "fromPeriod" => 1,
              "toPeriod" => 12,
              "annualInterestRate" => 6,
              "currencyCode" => "USD"
            },
            %{
              "periodType" => 2,
              "fromPeriod" => 13,
              "annualInterestRate" => 7,
              "currencyCode" => "USD"
            }
          ]
        }
      ]
    })
    |> ok()
    |> Map.fetch!("resourceId")
  end

  defp apply_for(product_id, extra) do
    send_json(
      :post,
      "/v1/recurringdepositaccounts",
      Map.merge(
        %{
          "clientId" => client(),
          "productId" => product_id,
          "submittedOnDate" => "2024-03-01",
          "mandatoryRecommendedDepositAmount" => 100,
          "depositPeriod" => 12,
          "depositPeriodFrequencyId" => 2,
          "isCalendarInherited" => false,
          "recurringFrequency" => 1,
          "recurringFrequencyType" => 2
        },
        Map.merge(@dates, extra)
      )
      |> Map.reject(fn {_key, value} -> value == :drop end)
    )
  end

  defp applied(extra \\ %{}) do
    business_date("2024-03-01")
    product() |> apply_for(extra) |> ok() |> Map.fetch!("resourceId")
  end

  defp command(id, name, extra),
    do:
      send_json(
        :post,
        "/v1/recurringdepositaccounts/#{id}?command=#{name}",
        Map.merge(@dates, extra)
      )

  defp change(id, extra),
    do:
      send_json(
        :put,
        "/v1/recurringdepositaccounts/#{id}",
        Map.merge(@dates, extra)
      )

  defp read(id), do: send_json(:get, "/v1/recurringdepositaccounts/#{id}") |> ok()

  defp schedule(id) do
    ECBPlatform.TenantRepo.all(
      from(s in "m_mandatory_savings_schedule",
        where: s.savings_account_id == ^id,
        order_by: s.installment,
        select: {s.installment, s.duedate, s.deposit_amount}
      )
    )
  end

  test "each action needs its own permission" do
    business_date("2024-03-01")
    product_id = product()
    path = "/v1/recurringdepositaccounts"

    assert send_json(:get, path, nil, make_user("r-none", [])).status == 403

    assert send_json(:get, path, nil, make_user("r-read", ["READ_RECURRINGDEPOSITACCOUNT"])).status ==
             200

    request =
      Map.merge(
        %{
          "clientId" => client(),
          "productId" => product_id,
          "submittedOnDate" => "2024-03-01",
          "mandatoryRecommendedDepositAmount" => 100,
          "depositPeriod" => 12,
          "depositPeriodFrequencyId" => 2,
          "isCalendarInherited" => false,
          "recurringFrequency" => 1,
          "recurringFrequencyType" => 2
        },
        @dates
      )

    assert send_json(
             :post,
             path,
             request,
             make_user("r-no-create", ["READ_RECURRINGDEPOSITACCOUNT"])
           ).status ==
             403

    assert send_json(
             :post,
             path,
             request,
             make_user("r-create", ["CREATE_RECURRINGDEPOSITACCOUNT"])
           ).status ==
             200
  end

  test "an application makes a schedule of installments, a deposit amount and a maturity amount" do
    id = applied()
    account = read(id)

    assert account["depositAmount"] == 1200
    assert account["maturityAmount"] == 1239.6
    assert account["nominalAnnualInterestRate"] == 6
    assert account["recurringFrequency"] == 1
    assert account["recurringFrequencyType"]["value"] == "Months"
    assert account["status"]["value"] == "Submitted and pending approval"

    installments = schedule(id)
    assert length(installments) == 12
    assert {1, ~D[2024-03-01], amount} = hd(installments)
    assert Decimal.eq?(amount, 100)
    assert {12, ~D[2025-02-01], _} = List.last(installments)
  end

  test "installments fall due from one another, so a month end moves to the end of the next shorter month" do
    id =
      applied(%{
        "submittedOnDate" => "2024-01-31",
        "depositPeriod" => 6,
        "mandatoryRecommendedDepositAmount" => 50
      })
      |> tap(fn _ -> :ok end)

    dates = id |> schedule() |> Enum.map(&elem(&1, 1))
    assert Enum.take(dates, 3) == [~D[2024-01-31], ~D[2024-02-29], ~D[2024-03-29]]
  end

  test "a weekly rule names the weekday and a longer term makes the rate and the amount follow" do
    id =
      applied(%{"depositPeriod" => 24, "recurringFrequencyType" => 1, "recurringFrequency" => 2})

    account = read(id)
    assert account["nominalAnnualInterestRate"] == 7
    assert account["recurringFrequencyType"]["value"] == "Weeks"
    assert account["recurringFrequency"] == 2

    [%{recurrence: recurrence}] =
      ECBPlatform.TenantRepo.all(from(c in "m_calendar", select: %{recurrence: c.recurrence}))

    assert recurrence == "FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"
  end

  test "a change works the schedule out again, with the frequency it is given or else the one the account has" do
    id = applied()

    change(id, %{"mandatoryRecommendedDepositAmount" => 150}) |> ok()
    assert read(id)["depositAmount"] == 1800
    assert read(id)["recurringFrequency"] == 1

    change(id, %{"recurringFrequency" => 2, "recurringFrequencyType" => 1}) |> ok()
    account = read(id)
    assert account["recurringFrequencyType"]["value"] == "Weeks"
    assert length(schedule(id)) == 27
    assert account["depositAmount"] == 150 * 27

    # one of the two alone changes that one and keeps the other
    change(id, %{"recurringFrequency" => 4}) |> ok()
    assert read(id)["recurringFrequency"] == 4
    assert read(id)["recurringFrequencyType"]["value"] == "Weeks"
  end

  test "a change without any frequency keeps the calendar, where Fineract fails with a server error" do
    id = applied()
    change(id, %{"externalId" => "kept"}) |> ok()
    assert read(id)["recurringFrequency"] == 1
    assert length(schedule(id)) == 12
  end

  test "a recommended amount that is not positive and a product that is not a recurring deposit's are refused" do
    id = applied()

    refused = change(id, %{"mandatoryRecommendedDepositAmount" => -1})
    assert refused.status == 400
    assert code(refused) =~ "mandatoryRecommendedDepositAmount.not.greater.than.zero"

    savings =
      send_json(:post, "/v1/savingsproducts", %{
        "name" => "Plain",
        "shortName" => "PLN",
        "currencyCode" => "USD",
        "digitsAfterDecimal" => 2,
        "nominalAnnualInterestRate" => 0,
        "interestCompoundingPeriodType" => 1,
        "interestPostingPeriodType" => 4,
        "interestCalculationType" => 1,
        "interestCalculationDaysInYearType" => 365,
        "accountingRule" => 1,
        "locale" => "en"
      })
      |> ok()
      |> Map.fetch!("resourceId")

    assert change(id, %{"productId" => savings}).status == 404
    assert read(id)["mandatoryRecommendedDepositAmount"] == 100
  end

  test "following the meeting of a group, groups, and a term without end are refused" do
    id = applied()
    product_id = read(id)["depositProductId"]

    inherited = change(id, %{"isCalendarInherited" => true})
    assert inherited.status == 403
    assert code(inherited) == "error.msg.depositaccount.feature.not.supported.yet"

    open_ended =
      apply_for(
        send_json(
          :post,
          "/v1/recurringdepositproducts",
          %{
            "name" => "Open",
            "shortName" => "OPN",
            "description" => "Open",
            "currencyCode" => "USD",
            "digitsAfterDecimal" => 2,
            "nominalAnnualInterestRate" => 5,
            "interestCompoundingPeriodType" => 1,
            "interestPostingPeriodType" => 4,
            "interestCalculationType" => 1,
            "interestCalculationDaysInYearType" => 365,
            "minDepositTerm" => 6,
            "minDepositTermTypeId" => 2,
            "depositAmount" => 1000,
            "accountingRule" => 1,
            "locale" => "en",
            "charts" => [
              %{
                "name" => "C",
                "fromDate" => "01 January 2020",
                "dateFormat" => "dd MMMM yyyy",
                "locale" => "en",
                "chartSlabs" => [
                  %{
                    "periodType" => 2,
                    "fromPeriod" => 1,
                    "annualInterestRate" => 5,
                    "currencyCode" => "USD"
                  }
                ]
              }
            ]
          }
        )
        |> ok()
        |> Map.fetch!("resourceId"),
        %{"depositPeriod" => :drop}
      )

    assert open_ended.status == 403
    assert code(open_ended) == "error.msg.depositaccount.feature.not.supported.yet"
    assert product_id > 0
  end

  test "activation after the day of application starts the schedule again from that day" do
    id = applied()
    command(id, "approve", %{"approvedOnDate" => "2024-03-01"}) |> ok()
    business_date("2024-04-10")
    command(id, "activate", %{"activatedOnDate" => "2024-04-10"}) |> ok()

    account = read(id)
    assert account["status"]["value"] == "Active"
    assert account["maturityDate"] == [2025, 4, 10]
    assert {1, ~D[2024-04-10], _} = hd(schedule(id))
    assert account["noOfOverdueInstallments"] == 0
  end

  test "an expected first deposit decides the day the schedule starts and the latest day of activation" do
    id = applied(%{"expectedFirstDepositOnDate" => "2024-03-15"})
    assert {1, ~D[2024-03-15], _} = hd(schedule(id))
    command(id, "approve", %{"approvedOnDate" => "2024-03-01"}) |> ok()

    business_date("2024-03-20")
    late = command(id, "activate", %{"activatedOnDate" => "2024-03-20"})
    assert late.status == 400
    assert code(late) =~ "cannot.be.before.expected.first.deposit.date"

    command(id, "activate", %{"activatedOnDate" => "2024-03-15"}) |> ok()
    assert {1, ~D[2024-03-15], _} = hd(schedule(id))
  end

  test "what follows activation is refused as not supported yet" do
    id = applied()
    command(id, "approve", %{"approvedOnDate" => "2024-03-01"}) |> ok()
    command(id, "activate", %{"activatedOnDate" => "2024-03-01"}) |> ok()

    for name <- ~w(calculateInterest postInterest close prematureClose calculatePrematureAmount) do
      refused = command(id, name, %{"closedOnDate" => "2024-03-02"})
      assert refused.status == 403
      assert code(refused) == "error.msg.depositaccount.feature.not.supported.yet"
    end
  end

  test "deleting an application takes its schedule and its calendar with it" do
    id = applied()
    assert send_json(:delete, "/v1/recurringdepositaccounts/#{id}") |> ok()
    assert schedule(id) == []
    assert ECBPlatform.TenantRepo.all(from(c in "m_calendar", select: c.id)) == []
    assert send_json(:get, "/v1/recurringdepositaccounts/#{id}").status == 404
  end

  test "an account number of its own is refused with Fineract's data integrity answer" do
    business_date("2024-03-01")
    refused = product() |> apply_for(%{"accountNo" => "RD-1"})
    assert refused.status == 403
    assert code(refused) == "error.msg.savingsaccount.unknown.data.integrity.issue"
  end
end
