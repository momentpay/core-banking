defmodule ECBApiFineract.SavingsAccountControlsTest do
  @moduledoc """
  What can be done to hold an account back or look after it, beyond the responses recorded from Fineract (those are
  in `ScenariosTest`): blocking, holding an amount, the savings officer, the dormancy job and the search of the
  transactions of an account. Permissions, the rules the recordings do not reach and what is refused because it is
  not built yet.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "yyyy-MM-dd", "locale" => "en"}

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp ok(conn) do
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp date(offset), do: Date.utc_today() |> Date.add(offset) |> Date.to_iso8601()

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
    send_json(
      :post,
      "/v1/savingsproducts",
      Map.merge(
        %{
          "name" => "Basic #{System.unique_integer([:positive])}",
          "shortName" => "B#{System.unique_integer([:positive])}" |> String.slice(0, 4),
          "currencyCode" => "USD",
          "digitsAfterDecimal" => 2,
          "nominalAnnualInterestRate" => 0,
          "interestCompoundingPeriodType" => 1,
          "interestPostingPeriodType" => 4,
          "interestCalculationType" => 1,
          "interestCalculationDaysInYearType" => 365,
          "accountingRule" => 1,
          "locale" => "en"
        },
        extra
      )
    )
    |> ok()
    |> Map.fetch!("resourceId")
  end

  defp payment_type do
    send_json(:post, "/v1/paymenttypes", %{
      "name" => "Cash #{System.unique_integer([:positive])}",
      "description" => "c",
      "isCashPayment" => true,
      "position" => 1
    })
    |> ok()
    |> Map.fetch!("resourceId")
  end

  # an active account activated on `on`, holding `balance` from that day
  defp account(product_id, balance, on \\ nil) do
    on = on || date(0)
    payment = payment_type()

    id =
      send_json(
        :post,
        "/v1/savingsaccounts",
        Map.merge(
          %{"clientId" => client(), "productId" => product_id, "submittedOnDate" => on},
          @dates
        )
      )
      |> ok()
      |> Map.fetch!("resourceId")

    command(id, "approve", %{"approvedOnDate" => on}) |> ok()
    command(id, "activate", %{"activatedOnDate" => on}) |> ok()
    if balance > 0, do: deposit(id, balance, payment, on)
    id
  end

  defp command(id, name, extra),
    do: send_json(:post, "/v1/savingsaccounts/#{id}?command=#{name}", Map.merge(@dates, extra))

  defp money(id, kind, amount, payment, on) do
    send_json(
      :post,
      "/v1/savingsaccounts/#{id}/transactions?command=#{kind}",
      Map.merge(
        %{"transactionDate" => on, "transactionAmount" => amount, "paymentTypeId" => payment},
        @dates
      )
    )
  end

  defp deposit(id, amount, payment, on \\ nil),
    do: id |> money("deposit", amount, payment, on || date(0)) |> ok()

  defp read(id), do: send_json(:get, "/v1/savingsaccounts/#{id}") |> ok()
  defp balance(id), do: read(id)["summary"]["accountBalance"]

  defp code(conn), do: hd(body(conn)["errors"])["userMessageGlobalisationCode"]

  describe "blocking" do
    test "a blocked account takes no money in or out, and unblocking lets it again" do
      id = account(product(), 100)
      payment = payment_type()

      assert command(id, "block", %{"reasonForBlock" => "court order"})
             |> ok()
             |> get_in(["changes", "subStatus", "value"]) ==
               "Block"

      assert read(id)["reasonForBlock"] == "court order"
      assert money(id, "deposit", 5, payment, date(0)).status == 403
      assert money(id, "withdrawal", 5, payment, date(0)).status == 403

      assert command(id, "unblock", %{}) |> ok() |> get_in(["changes", "subStatus", "value"]) ==
               "None"

      assert money(id, "deposit", 5, payment, date(0)).status == 200
    end

    test "blocking the credits only refuses deposits, blocking the debits only withdrawals" do
      id = account(product(), 100)
      payment = payment_type()

      command(id, "blockCredit", %{"reasonForBlock" => "r"}) |> ok()
      assert money(id, "deposit", 5, payment, date(0)).status == 403
      assert money(id, "withdrawal", 5, payment, date(0)).status == 200

      # with the debits blocked as well the account is blocked altogether
      assert command(id, "blockDebit", %{"reasonForBlock" => "r"})
             |> ok()
             |> get_in(["changes", "subStatus", "value"]) == "Block"

      assert command(id, "unblockCredit", %{})
             |> ok()
             |> get_in(["changes", "subStatus", "value"]) ==
               "BlockDebit"

      assert money(id, "deposit", 5, payment, date(0)).status == 200
      assert money(id, "withdrawal", 5, payment, date(0)).status == 403
    end

    test "a block needs its reason, and an account that is not blocked cannot be unblocked" do
      id = account(product(), 0)

      conn = command(id, "block", %{})
      assert conn.status == 403
      assert code(conn) == "Reason For Block is Mandatory"

      assert command(id, "unblock", %{}).status == 400
      assert command(id, "unblockCredit", %{}).status == 400
    end

    test "a blocked account cannot be closed" do
      id = account(product(), 0)
      command(id, "block", %{"reasonForBlock" => "r"}) |> ok()

      conn = command(id, "close", %{"closedOnDate" => date(0)})
      assert conn.status == 400
      assert code(conn) == "validation.msg.savingsaccount.account.is.in.blocked.state"
    end

    test "each action needs its own permission" do
      id = account(product(), 0)

      assert command_as(id, "block", %{"reasonForBlock" => "r"}, make_user("b-none", [])).status ==
               403

      assert command_as(
               id,
               "block",
               %{"reasonForBlock" => "r"},
               make_user("b-yes", ["BLOCK_SAVINGSACCOUNT"])
             ).status == 200
    end
  end

  defp command_as(id, name, extra, auth),
    do:
      send_json(
        :post,
        "/v1/savingsaccounts/#{id}?command=#{name}",
        Map.merge(@dates, extra),
        auth
      )

  describe "holding an amount" do
    defp hold(id, amount, extra \\ %{}) do
      send_json(
        :post,
        "/v1/savingsaccounts/#{id}/transactions?command=holdAmount",
        Map.merge(
          %{
            "transactionDate" => date(0),
            "transactionAmount" => amount,
            "reasonForBlock" => "dispute"
          },
          Map.merge(@dates, extra)
        )
      )
    end

    defp release(id, hold_id),
      do:
        send_json(
          :post,
          "/v1/savingsaccounts/#{id}/transactions/#{hold_id}?command=releaseAmount",
          @dates
        )

    test "what is on hold cannot be paid out until it is released" do
      id = account(product(), 100)
      payment = payment_type()

      hold_id = hold(id, 70) |> ok() |> Map.fetch!("resourceId")
      account = read(id)
      assert account["savingsAmountOnHold"] == 70
      assert account["summary"]["availableBalance"] == 30
      assert account["summary"]["accountBalance"] == 100

      assert money(id, "withdrawal", 40, payment, date(0)).status == 403
      assert money(id, "withdrawal", 30, payment, date(0)).status == 200

      assert release(id, hold_id).status == 200
      assert read(id)["savingsAmountOnHold"] == 0
      assert money(id, "withdrawal", 40, payment, date(0)).status == 200
    end

    test "more than can be spared cannot be held, and what is released cannot be released again" do
      id = account(product(), 50)

      assert hold(id, 80).status == 400
      assert hold(id, 0).status == 400
      assert hold(id, 10, %{"reasonForBlock" => ""}).status == 400

      hold_id = hold(id, 20) |> ok() |> Map.fetch!("resourceId")
      assert release(id, hold_id).status == 200
      assert release(id, hold_id).status != 200
    end

    test "an account with an amount on hold cannot be closed" do
      id = account(product(), 50)
      hold(id, 20) |> ok()

      conn = command(id, "close", %{"closedOnDate" => date(0)})
      assert conn.status == 400

      assert code(conn) ==
               "validation.msg.savingsaccount.amount.is.on.hold.release.the.amount.to.continue"
    end

    test "each action needs its own permission" do
      id = account(product(), 50)

      request =
        Map.merge(
          %{"transactionAmount" => 5, "transactionDate" => date(0), "reasonForBlock" => "r"},
          @dates
        )

      path = "/v1/savingsaccounts/#{id}/transactions?command=holdAmount"

      assert send_json(:post, path, request, make_user("h-none", [])).status == 403

      assert send_json(:post, path, request, make_user("h-yes", ["HOLDAMOUNT_SAVINGSACCOUNT"])).status ==
               200
    end
  end

  describe "the savings officer" do
    defp staff(name) do
      send_json(
        :post,
        "/v1/staff",
        Map.merge(@dates, %{
          "officeId" => 1,
          "firstname" => name,
          "lastname" => "X",
          "isLoanOfficer" => true,
          "isActive" => true,
          "joiningDate" => "2020-01-01"
        })
      )
      |> ok()
      |> Map.fetch!("resourceId")
    end

    test "an officer is assigned, changed and taken away again" do
      id = account(product(), 0)
      first = staff("Sam")
      second = staff("Tia")

      assert command(id, "assignSavingsOfficer", %{
               "toSavingsOfficerId" => first,
               "assignmentDate" => date(0)
             })
             |> ok()
             |> get_in(["changes", "toSavingsOfficerId"]) == first

      assert read(id)["fieldOfficerId"] == first

      command(id, "assignSavingsOfficer", %{
        "fromSavingsOfficerId" => first,
        "toSavingsOfficerId" => second,
        "assignmentDate" => date(0)
      })
      |> ok()

      assert read(id)["fieldOfficerId"] == second

      command(id, "unassignSavingsOfficer", %{"unassignedDate" => date(0)}) |> ok()
      assert read(id)["fieldOfficerId"] == 0
    end

    test "the officer named as the current one must be the account's, and an unassigned account has none to take away" do
      id = account(product(), 0)
      first = staff("Una")

      conn = command(id, "unassignSavingsOfficer", %{"unassignedDate" => date(0)})
      assert conn.status == 403
      assert code(conn) == "error.msg.savings.account.not.assigned.to.savings.officer"

      conn =
        command(id, "assignSavingsOfficer", %{
          "fromSavingsOfficerId" => first,
          "toSavingsOfficerId" => first,
          "assignmentDate" => date(0)
        })

      assert conn.status == 403
      assert code(conn) == "error.msg.savings.account.not.assigned.to.savings.officer"
    end

    test "an assignment cannot be dated in the future" do
      id = account(product(), 0)

      conn =
        command(id, "assignSavingsOfficer", %{
          "toSavingsOfficerId" => staff("Fay"),
          "assignmentDate" => date(5)
        })

      assert conn.status == 403
      assert code(conn) == "error.msg.savings.assignment.date.cannot.be.a.future.date"
    end
  end

  describe "the dormancy job" do
    @tracking %{
      "isDormancyTrackingActive" => true,
      "daysToInactive" => 10,
      "daysToDormancy" => 20,
      "daysToEscheat" => 30
    }

    defp run_dormancy_job,
      do: assert(send_json(:post, "/v1/jobs/21?command=executeJob", %{}).status == 202)

    test "an account idle for the days of a stage reaches it, and money moving makes it active again" do
      product = product(@tracking)
      idle = account(product, 100, date(-12))
      older = account(product, 100, date(-25))
      busy = account(product, 100, date(-12))
      untracked = account(product(), 100, date(-100))
      deposit(busy, 5, payment_type(), date(-1))

      run_dormancy_job()

      assert read(idle)["subStatus"]["value"] == "Inactive"
      assert read(older)["subStatus"]["value"] == "Dormant"
      assert read(busy)["subStatus"]["value"] == "None"
      assert read(untracked)["subStatus"]["value"] == "None"

      # the days left to the next stage count from the last deposit or withdrawal
      assert read(idle)["daysToDormancy"] == 8
      assert read(busy)["daysToInactive"] == 9

      deposit(older, 1, payment_type())
      assert read(older)["subStatus"]["value"] == "None"
    end

    test "an account idle for the days to escheat is closed and its balance escheated" do
      id = account(product(@tracking), 120, date(-40))
      run_dormancy_job()

      account = read(id)
      assert account["status"]["value"] == "Closed"
      assert account["subStatus"]["value"] == "Escheat"
      assert account["summary"]["accountBalance"] == 120

      [escheat] =
        send_json(:get, "/v1/savingsaccounts/#{id}/transactions/search?types=19")
        |> ok()
        |> Map.fetch!("content")

      assert escheat["amount"] == 120
      assert escheat["transactionType"]["escheat"] == true
    end

    test "an inactive account pays its no activity fee on the balance it has" do
      fee =
        send_json(:post, "/v1/charges", %{
          "name" => "No activity #{System.unique_integer([:positive])}",
          "currencyCode" => "USD",
          "chargeAppliesTo" => 2,
          "chargeTimeType" => 16,
          "chargeCalculationType" => 2,
          "amount" => 1.5,
          "active" => true,
          "penalty" => false,
          "locale" => "en"
        })
        |> ok()
        |> Map.fetch!("resourceId")

      id = account(product(@tracking), 200, date(-12))

      send_json(
        :post,
        "/v1/savingsaccounts/#{id}/charges",
        Map.merge(%{"chargeId" => fee, "amount" => 1.5}, @dates)
      )
      |> ok()

      run_dormancy_job()
      assert balance(id) == 197
      assert read(id)["subStatus"]["value"] == "Inactive"

      # and not again on the next run
      run_dormancy_job()
      assert balance(id) == 197
    end
  end

  describe "searching the transactions" do
    defp search(id, query),
      do: send_json(:get, "/v1/savingsaccounts/#{id}/transactions/search" <> query)

    defp ids(conn), do: conn |> ok() |> Map.fetch!("content") |> Enum.map(& &1["id"])

    test "answers a page of the newest first, and narrows by amount, type and direction" do
      id = account(product(), 0)
      payment = payment_type()
      first = deposit(id, 100, payment)["resourceId"]
      second = deposit(id, 40, payment)["resourceId"]
      third = money(id, "withdrawal", 30, payment, date(0)) |> ok() |> Map.fetch!("resourceId")

      assert ids(search(id, "")) == [third, second, first]
      assert ids(search(id, "?types=1")) == [second, first]
      assert ids(search(id, "?debit=true")) == [third]
      assert ids(search(id, "?credit=true")) == [second, first]
      assert ids(search(id, "?fromAmount=35&toAmount=100")) == [second, first]
      assert ids(search(id, "?orderBy=amount&sortOrder=ASC")) == [third, second, first]

      page = search(id, "?limit=2&offset=1") |> ok()
      assert page["total"] == 3
      assert Enum.map(page["content"], & &1["id"]) == [first]
      assert page["pageable"]["pageNumber"] == 1
      assert page["pageable"]["pageSize"] == 2
    end

    test "refuses what cannot be searched on, as Fineract does" do
      id = account(product(), 0)

      assert search(id, "?orderBy=bogus&sortOrder=ASC").status == 400
      assert search(id, "?fromDate=notadate").status == 400
      assert search(id, "?limit=0").status == 500
      assert search(id, "?orderBy=amount").status == 500
      assert search(id, "?fromAmount=abc").status == 404
      assert search(id, "?sortOrder=sideways").status == 404
    end

    test "needs permission to read" do
      id = account(product(), 0)

      assert send_json(
               :get,
               "/v1/savingsaccounts/#{id}/transactions/search",
               nil,
               make_user("s-none", [])
             ).status == 403

      assert send_json(
               :get,
               "/v1/savingsaccounts/#{id}/transactions/search",
               nil,
               make_user("s-read", ["READ_SAVINGSACCOUNT"])
             ).status == 200
    end

    test "the advanced query is refused as not supported yet" do
      id = account(product(), 0)
      conn = send_json(:post, "/v1/savingsaccounts/#{id}/transactions/query", %{"request" => %{}})
      assert conn.status == 403
      assert code(conn) == "error.msg.savingsaccount.feature.not.supported.yet"
    end
  end
end
