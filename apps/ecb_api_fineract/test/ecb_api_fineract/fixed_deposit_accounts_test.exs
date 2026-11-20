defmodule ECBApiFineract.FixedDepositAccountsTest do
  @moduledoc """
  Fixed deposit accounts beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions, the
  life of an application, the maturity it works out and what is refused because it is not built yet.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "yyyy-MM-dd", "locale" => "en"}

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp ok(conn) do
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp today, do: Date.to_iso8601(Date.utc_today())
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

  defp product(extra \\ %{}) do
    n = System.unique_integer([:positive])

    send_json(
      :post,
      "/v1/fixeddepositproducts",
      Map.merge(
        %{
          "name" => "FD #{n}",
          "shortName" => "F#{rem(n, 1000)}",
          "description" => "Fixed",
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
        },
        extra
      )
    )
    |> ok()
    |> Map.fetch!("resourceId")
  end

  defp apply_for(product_id, extra \\ %{}) do
    send_json(
      :post,
      "/v1/fixeddepositaccounts",
      Map.merge(
        %{
          "clientId" => client(),
          "productId" => product_id,
          "submittedOnDate" => today(),
          "depositAmount" => 5000,
          "depositPeriod" => 12,
          "depositPeriodFrequencyId" => 2
        },
        Map.merge(@dates, extra)
      )
    )
  end

  defp command(id, name, extra),
    do:
      send_json(:post, "/v1/fixeddepositaccounts/#{id}?command=#{name}", Map.merge(@dates, extra))

  defp read(id), do: send_json(:get, "/v1/fixeddepositaccounts/#{id}") |> ok()

  test "each action needs its own permission" do
    product_id = product()
    path = "/v1/fixeddepositaccounts"

    assert send_json(:get, path, nil, make_user("a-none", [])).status == 403

    assert send_json(:get, path, nil, make_user("a-read", ["READ_FIXEDDEPOSITACCOUNT"])).status ==
             200

    assert apply_for(product_id).status == 200

    request =
      Map.merge(
        %{
          "clientId" => client(),
          "productId" => product_id,
          "submittedOnDate" => today(),
          "depositAmount" => 5000,
          "depositPeriod" => 12,
          "depositPeriodFrequencyId" => 2
        },
        @dates
      )

    assert send_json(:post, path, request, make_user("a-no-create", ["READ_FIXEDDEPOSITACCOUNT"])).status ==
             403

    assert send_json(:post, path, request, make_user("a-create", ["CREATE_FIXEDDEPOSITACCOUNT"])).status ==
             200
  end

  test "an application works out the rate, the maturity date and the maturity amount from the chart" do
    id = product() |> apply_for() |> ok() |> Map.fetch!("resourceId")
    account = read(id)

    assert account["nominalAnnualInterestRate"] == 6
    assert account["maturityAmount"] == 5309.15
    assert account["status"]["value"] == "Submitted and pending approval"
    assert [_, _, _] = Enum.take(account["maturityDate"], 3)
    assert hd(account["accountChart"]["chartSlabs"])["fromPeriod"] == 1

    longer = product() |> apply_for(%{"depositPeriod" => 24}) |> ok() |> Map.fetch!("resourceId")
    assert read(longer)["nominalAnnualInterestRate"] == 7
  end

  test "an application is approved and activated, and activating makes the deposit" do
    id = product() |> apply_for() |> ok() |> Map.fetch!("resourceId")

    assert command(id, "activate", %{"activatedOnDate" => today()}).status == 400
    command(id, "approve", %{"approvedOnDate" => today()}) |> ok()
    command(id, "activate", %{"activatedOnDate" => today()}) |> ok()

    account = send_json(:get, "/v1/fixeddepositaccounts/#{id}?associations=transactions") |> ok()
    assert account["status"]["value"] == "Active"
    assert account["summary"]["accountBalance"] == 5000

    assert [deposit] = account["transactions"]
    assert deposit["amount"] == 5000
    assert deposit["transactionType"]["value"] == "Deposit"
    account["transactions"]
  end

  test "an application can be changed and deleted only until it is approved" do
    id = product() |> apply_for() |> ok() |> Map.fetch!("resourceId")

    changed =
      send_json(
        :put,
        "/v1/fixeddepositaccounts/#{id}",
        Map.merge(@dates, %{"depositAmount" => 6000})
      )
      |> ok()

    assert changed["changes"] == %{"depositAmount" => 6000}
    assert read(id)["depositAmount"] == 6000

    command(id, "approve", %{"approvedOnDate" => today()}) |> ok()

    assert send_json(
             :put,
             "/v1/fixeddepositaccounts/#{id}",
             Map.merge(@dates, %{"depositAmount" => 7000})
           ).status == 400

    assert send_json(:delete, "/v1/fixeddepositaccounts/#{id}").status == 400

    other = product() |> apply_for() |> ok() |> Map.fetch!("resourceId")
    assert send_json(:delete, "/v1/fixeddepositaccounts/#{other}").status == 200
    assert send_json(:get, "/v1/fixeddepositaccounts/#{other}").status == 404
  end

  test "a term outside the product's limits or not in its steps is refused" do
    product_id = product()

    short = apply_for(product_id, %{"depositPeriod" => 3})
    assert short.status == 400

    assert code(short) ==
             "validation.msg.fixeddepositaccount.deposit.period.not.between.min.and.max.deposit.term"

    odd = apply_for(product_id, %{"depositPeriod" => 7})
    assert odd.status == 400
    assert code(odd) == "validation.msg.fixeddepositaccount.deposit.period.not.multiple.of.term"
  end

  test "linking a savings account and withholding tax are refused as not supported yet" do
    product_id = product()

    linked = apply_for(product_id, %{"linkAccountId" => 1, "transferInterestToSavings" => true})
    assert linked.status == 403
    assert code(linked) == "error.msg.depositaccount.feature.not.supported.yet"

    assert apply_for(product_id, %{"withHoldTax" => true}).status == 400
  end

  test "a savings account is not a fixed deposit account" do
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

    id =
      send_json(
        :post,
        "/v1/savingsaccounts",
        Map.merge(
          %{"clientId" => client(), "productId" => savings, "submittedOnDate" => today()},
          @dates
        )
      )
      |> ok()
      |> Map.fetch!("resourceId")

    assert send_json(:get, "/v1/fixeddepositaccounts/#{id}").status == 404

    assert send_json(
             :put,
             "/v1/fixeddepositaccounts/#{id}",
             Map.merge(@dates, %{"depositAmount" => 1})
           ).status == 404
  end

  describe "interest, closing and maturity" do
    # a product with terms in days, so that a deposit matures within days
    defp day_product do
      product(%{
        "minDepositTerm" => 1,
        "minDepositTermTypeId" => 0,
        "maxDepositTerm" => 400,
        "maxDepositTermTypeId" => 0,
        "inMultiplesOfDepositTerm" => 1,
        "inMultiplesOfDepositTermTypeId" => 0,
        "preClosurePenalApplicable" => false,
        "charts" => [
          %{
            "name" => "Days",
            "fromDate" => "01 January 2020",
            "dateFormat" => "dd MMMM yyyy",
            "locale" => "en",
            "chartSlabs" => [
              %{
                "periodType" => 0,
                "fromPeriod" => 1,
                "toPeriod" => 400,
                "annualInterestRate" => 6,
                "currencyCode" => "USD"
              }
            ]
          }
        ]
      })
    end

    defp business_date(date) do
      send_json(:put, "/v1/configurations/name/enable-business-date", %{"enabled" => true})
      |> ok()

      send_json(:post, "/v1/businessdate", %{
        "type" => "BUSINESS_DATE",
        "date" => date,
        "dateFormat" => "yyyy-MM-dd",
        "locale" => "en"
      })
      |> ok()
    end

    defp live_deposit(days) do
      business_date("2024-03-01")

      id =
        day_product()
        |> apply_for(%{
          "submittedOnDate" => "2024-03-01",
          "depositPeriod" => days,
          "depositPeriodFrequencyId" => 0
        })
        |> ok()
        |> Map.fetch!("resourceId")

      command(id, "approve", %{"approvedOnDate" => "2024-03-01"}) |> ok()
      command(id, "activate", %{"activatedOnDate" => "2024-03-01"}) |> ok()
      id
    end

    defp closing(id, name, extra),
      do:
        command(
          id,
          name,
          Map.merge(%{"closedOnDate" => "2024-03-11", "onAccountClosureId" => 100}, extra)
        )

    test "the job matures a deposit at the end of its term and closing pays it out" do
      id = live_deposit(10)
      business_date("2024-03-11")

      assert closing(id, "close", %{}).status == 400
      assert code(closing(id, "close", %{})) =~ "not.in.matured.state"

      send_json(:post, "/v1/jobs/15?command=executeJob", %{})
      |> then(&assert(&1.status in [200, 202]))

      matured = read(id)
      assert matured["status"]["value"] == "Matured"
      assert matured["summary"]["accountBalance"] == matured["maturityAmount"]

      closed = closing(id, "close", %{"note" => "paid"}) |> ok()
      assert closed["changes"]["status"]["value"] == "Closed"
      assert closed["changes"]["note"] == "paid"
      assert read(id)["summary"]["accountBalance"] == 0
    end

    test "a deposit that has not matured is not matured by the job" do
      id = live_deposit(10)
      business_date("2024-03-05")
      send_json(:post, "/v1/jobs/15?command=executeJob", %{})
      assert read(id)["status"]["value"] == "Active"
    end

    test "closing early posts the interest earned, takes the balance out and closes the account" do
      id = live_deposit(60)
      business_date("2024-03-11")

      amount =
        command(id, "calculatePrematureAmount", %{"closedOnDate" => "2024-03-11"}) |> ok()

      assert amount["maturityAmount"] > 5000

      closed = closing(id, "prematureClose", %{}) |> ok()
      assert closed["changes"]["status"]["value"] == "Premature Closed"

      account =
        send_json(:get, "/v1/fixeddepositaccounts/#{id}?associations=transactions") |> ok()

      assert account["summary"]["accountBalance"] == 0

      assert [withdrawal, interest, deposit] = account["transactions"]
      assert withdrawal["transactionType"]["value"] == "Withdrawal"
      assert withdrawal["amount"] == amount["maturityAmount"]
      assert interest["transactionType"]["value"] == "Interest posting"
      assert deposit["amount"] == 5000
    end

    test "closing early cannot invest the money again and a closed deposit cannot be closed again" do
      id = live_deposit(60)
      business_date("2024-03-11")

      assert closing(id, "prematureClose", %{"onAccountClosureId" => 300}).status == 400
      closing(id, "prematureClose", %{}) |> ok()
      assert closing(id, "prematureClose", %{}).status == 400
      assert closing(id, "close", %{}).status == 400
    end

    test "paying a closed deposit into a savings account or investing it again is not supported yet" do
      id = live_deposit(10)
      business_date("2024-03-11")
      send_json(:post, "/v1/jobs/15?command=executeJob", %{})

      for closure <- [300, 400] do
        refused = closing(id, "close", %{"onAccountClosureId" => closure})
        assert refused.status == 403
        assert code(refused) == "error.msg.depositaccount.feature.not.supported.yet"
      end

      transfer =
        closing(id, "close", %{"onAccountClosureId" => 200, "toSavingsAccountId" => 99_999})

      assert transfer.status == 404

      assert read(id)["status"]["value"] == "Matured"
    end

    test "a fixed deposit cannot be withdrawn from or deposited into, only closed" do
      id = live_deposit(10)
      body = Map.merge(@dates, %{"transactionDate" => "2024-03-02", "transactionAmount" => 10})

      withdrawal =
        send_json(:post, "/v1/fixeddepositaccounts/#{id}/transactions?command=withdrawal", body)

      assert withdrawal.status == 503

      deposit =
        send_json(:post, "/v1/fixeddepositaccounts/#{id}/transactions?command=deposit", body)

      assert deposit.status == 403
      assert code(deposit) == "error.msg.depositaccount.feature.not.supported.yet"
    end

    test "interest is worked out and posted up to the end of the term and no further" do
      id = live_deposit(40)
      business_date("2025-03-01")

      command(id, "postInterest", %{}) |> ok()
      account = read(id)

      transactions = send_json(:get, "/v1/fixeddepositaccounts/#{id}/transactions") |> ok()

      postings =
        Enum.filter(transactions, &(&1["transactionType"]["value"] == "Interest posting"))

      assert length(postings) == 2
      assert account["summary"]["accountBalance"] > 5000
      assert account["status"]["value"] == "Active"
    end

    test "the transactions of a deposit and the template of closing it can be read" do
      id = live_deposit(10)
      [deposit] = send_json(:get, "/v1/fixeddepositaccounts/#{id}/transactions") |> ok()

      one =
        send_json(:get, "/v1/fixeddepositaccounts/#{id}/transactions/#{deposit["id"]}") |> ok()

      assert one["amount"] == 5000

      assert send_json(:get, "/v1/fixeddepositaccounts/#{id}/transactions/99999").status == 404

      template = send_json(:get, "/v1/fixeddepositaccounts/#{id}/template?command=close") |> ok()
      assert length(template["onAccountClosureOptions"]) == 4
      assert send_json(:get, "/v1/fixeddepositaccounts/#{id}/template").status == 204
    end
  end
end
