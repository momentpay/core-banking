defmodule ECBApiFineract.SavingsAccountsTest do
  @moduledoc """
  Savings accounts beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions, what
  is refused because it is not built yet, and what a savings product keeps once it has accounts.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "yyyy-MM-dd", "locale" => "en"}

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp today, do: Date.to_iso8601(Date.utc_today())

  defp client do
    conn =
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

    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp product(extra \\ %{}) do
    request =
      Map.merge(
        %{
          "name" => "Basic",
          "shortName" => "BSIC",
          "currencyCode" => "USD",
          "digitsAfterDecimal" => 2,
          "nominalAnnualInterestRate" => 5,
          "interestCompoundingPeriodType" => 1,
          "interestPostingPeriodType" => 4,
          "interestCalculationType" => 1,
          "interestCalculationDaysInYearType" => 365,
          "accountingRule" => 1,
          "locale" => "en"
        },
        extra
      )

    conn = send_json(:post, "/v1/savingsproducts", request)
    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp apply_for(client_id, product_id, extra \\ %{}) do
    request =
      Map.merge(
        %{"clientId" => client_id, "productId" => product_id, "submittedOnDate" => today()},
        Map.merge(@dates, extra)
      )

    send_json(:post, "/v1/savingsaccounts", request)
  end

  defp command(id, name, extra, auth \\ admin()),
    do:
      send_json(
        :post,
        "/v1/savingsaccounts/#{id}?command=#{name}",
        Map.merge(@dates, extra),
        auth
      )

  defp approved_account(product_extra \\ %{}) do
    conn = apply_for(client(), product(product_extra))
    assert conn.status == 200, conn.resp_body
    id = body(conn)["resourceId"]
    assert command(id, "approve", %{"approvedOnDate" => today()}).status == 200
    id
  end

  describe "permissions" do
    test "each action needs its own permission" do
      client_id = client()
      product_id = product()

      request = %{
        "clientId" => client_id,
        "productId" => product_id,
        "submittedOnDate" => today()
      }

      assert send_json(:get, "/v1/savingsaccounts", nil, make_user("sa-none", [])).status == 403

      assert send_json(
               :get,
               "/v1/savingsaccounts",
               nil,
               make_user("sa-read", ["READ_SAVINGSACCOUNT"])
             ).status == 200

      assert send_json(
               :post,
               "/v1/savingsaccounts",
               Map.merge(request, @dates),
               make_user("sa-no-create", ["READ_SAVINGSACCOUNT"])
             ).status == 403

      created =
        send_json(
          :post,
          "/v1/savingsaccounts",
          Map.merge(request, @dates),
          make_user("sa-create", ["CREATE_SAVINGSACCOUNT"])
        )

      assert created.status == 200
      id = body(created)["resourceId"]

      approve = %{"approvedOnDate" => today()}

      assert command(
               id,
               "approve",
               approve,
               make_user("sa-no-approve", ["CREATE_SAVINGSACCOUNT"])
             ).status == 403

      assert command(id, "approve", approve, make_user("sa-approve", ["APPROVE_SAVINGSACCOUNT"])).status ==
               200

      assert command(id, "undoApproval", %{}, make_user("sa-no-undo", ["APPROVE_SAVINGSACCOUNT"])).status ==
               403

      assert command(id, "activate", %{"activatedOnDate" => today()}, make_user("sa-no-act", [])).status ==
               403

      assert command(
               id,
               "activate",
               %{"activatedOnDate" => today()},
               make_user("sa-act", ["ACTIVATE_SAVINGSACCOUNT"])
             ).status ==
               200

      assert command(
               id,
               "close",
               %{"closedOnDate" => today()},
               make_user("sa-no-close", ["ACTIVATE_SAVINGSACCOUNT"])
             ).status ==
               403

      assert command(
               id,
               "close",
               %{"closedOnDate" => today()},
               make_user("sa-close", ["CLOSE_SAVINGSACCOUNT"])
             ).status ==
               200
    end
  end

  describe "what is not built yet" do
    test "an application with charges, a lien or tax withholding is refused" do
      client_id = client()
      product_id = product()

      for extra <- [
            %{"lienAllowed" => true},
            %{"withHoldTax" => true}
          ] do
        conn = apply_for(client_id, product_id, extra)
        assert conn.status == 403, conn.resp_body

        assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
                 "error.msg.savingsaccount.feature.not.supported.yet"
      end
    end

    test "activating an account that earns interest deposits the opening balance and works the interest out" do
      id =
        approved_account(%{
          "minRequiredOpeningBalance" => 365_000,
          "nominalAnnualInterestRate" => 10
        })

      assert command(id, "activate", %{"activatedOnDate" => today()}).status == 200

      summary = body(send_json(:get, "/v1/savingsaccounts/#{id}"))["summary"]
      assert summary["accountBalance"] == 365_000
      assert summary["totalInterestEarned"] == 100
      assert summary["interestNotPosted"] == 100
    end

    test "a command that does not exist is not recognized" do
      id = approved_account()
      conn = command(id, "frobnicate", %{})
      assert conn.status == 400
    end
  end

  describe "the lifecycle" do
    test "an account can be taken back to an application, approved again and activated" do
      id = approved_account()

      # taking the approval back knows no dates, only a note
      assert send_json(:post, "/v1/savingsaccounts/#{id}?command=undoApproval", %{"note" => "x"}).status ==
               200

      assert body(send_json(:get, "/v1/savingsaccounts/#{id}"))["status"]["value"] ==
               "Submitted and pending approval"

      assert command(id, "approve", %{"approvedOnDate" => today()}).status == 200
      assert command(id, "activate", %{"activatedOnDate" => today()}).status == 200

      account = body(send_json(:get, "/v1/savingsaccounts/#{id}"))
      assert account["status"]["value"] == "Active"
      assert account["timeline"]["activatedByUsername"] == "mifos"
    end

    test "an active account with a balance cannot be closed" do
      id = approved_account()
      assert command(id, "activate", %{"activatedOnDate" => today()}).status == 200

      ECBPlatform.TenantRepo.query!(
        "UPDATE m_savings_account SET account_balance_derived = 10 WHERE id = $1",
        [id]
      )

      conn = command(id, "close", %{"closedOnDate" => today()})
      assert conn.status == 400

      assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
               "validation.msg.savingsaccount.close.results.in.balance.not.zero"
    end
  end

  @zero %{"nominalAnnualInterestRate" => 0}

  defp live_account(product_extra \\ @zero) do
    id = approved_account(product_extra)
    assert command(id, "activate", %{"activatedOnDate" => today()}).status == 200
    id
  end

  defp money(id, kind, amount, extra \\ %{}, auth \\ admin()) do
    body =
      Map.merge(
        %{
          "transactionDate" => today(),
          "transactionAmount" => amount,
          "paymentTypeId" => 1
        },
        Map.merge(@dates, extra)
      )

    send_json(:post, "/v1/savingsaccounts/#{id}/transactions?command=#{kind}", body, auth)
  end

  describe "money in and out" do
    test "each kind of money movement needs its own permission" do
      id = live_account()

      assert money(id, "deposit", 10, %{}, make_user("tx-none", ["READ_SAVINGSACCOUNT"])).status ==
               403

      assert money(id, "deposit", 10, %{}, make_user("tx-dep", ["DEPOSIT_SAVINGSACCOUNT"])).status ==
               200

      assert money(id, "withdrawal", 5, %{}, make_user("tx-no-wd", ["DEPOSIT_SAVINGSACCOUNT"])).status ==
               403

      assert money(id, "withdrawal", 5, %{}, make_user("tx-wd", ["WITHDRAWAL_SAVINGSACCOUNT"])).status ==
               200

      tx = body(money(id, "deposit", 20))["resourceId"]
      undo = "/v1/savingsaccounts/#{id}/transactions/#{tx}?command=undo"

      assert send_json(:post, undo, %{}, make_user("tx-no-undo", ["DEPOSIT_SAVINGSACCOUNT"])).status ==
               403

      assert send_json(:post, undo, %{}, make_user("tx-undo", ["UNDOTRANSACTION_SAVINGSACCOUNT"])).status ==
               200
    end

    test "an account that earns interest takes money in and out, and its interest can be worked out and posted" do
      id = live_account(%{"nominalAnnualInterestRate" => 10})

      assert money(id, "deposit", 365_000).status == 200
      assert money(id, "withdrawal", 365_000 - 1000).status == 200

      # a day of interest on what was left at the end of the day
      summary = body(send_json(:get, "/v1/savingsaccounts/#{id}"))["summary"]
      assert summary["accountBalance"] == 1000
      assert summary["totalInterestEarned"] == 0.27

      assert command(id, "calculateInterest", %{}).status == 200
      assert command(id, "postInterest", %{}).status == 200

      # nothing is posted before the period has ended
      assert body(send_json(:get, "/v1/savingsaccounts/#{id}"))["summary"]["totalInterestPosted"] ==
               0
    end

    test "an opening balance is deposited when the account is activated" do
      id = live_account(%{"nominalAnnualInterestRate" => 0, "minRequiredOpeningBalance" => 100})

      account = body(send_json(:get, "/v1/savingsaccounts/#{id}?associations=transactions"))
      assert account["summary"]["accountBalance"] == 100

      assert [deposit] = account["transactions"]
      assert deposit["amount"] == 100
      assert deposit["transactionType"]["value"] == "Deposit"
    end

    test "a forced withdrawal may take the balance below nothing as far as the configuration allows" do
      id = live_account()
      assert money(id, "deposit", 50).status == 200

      # without the configuration a forced withdrawal is a plain one
      assert money(id, "force-withdrawal", 80).status == 403

      assert send_json(
               :put,
               "/v1/configurations/name/allow-force-withdrawal-on-savings-account",
               %{
                 "enabled" => true,
                 "value" => 100
               }
             ).status == 200

      try do
        assert money(id, "force-withdrawal", 80).status == 200
        assert money(id, "force-withdrawal", 80).status == 403
        assert money(id, "withdrawal", 1).status == 403

        assert body(send_json(:get, "/v1/savingsaccounts/#{id}"))["summary"]["accountBalance"] ==
                 -30
      after
        # the configuration is the tenant's, and the other tests find it as it was seeded
        send_json(:put, "/v1/configurations/name/allow-force-withdrawal-on-savings-account", %{
          "enabled" => false,
          "value" => 0
        })
      end
    end

    test "an account is closed with its balance taken out when asked" do
      id = live_account()
      assert money(id, "deposit", 40).status == 200

      assert command(id, "close", %{"closedOnDate" => today()}).status == 400

      conn =
        command(id, "close", %{
          "closedOnDate" => today(),
          "withdrawBalance" => true,
          "paymentTypeId" => 1
        })

      assert conn.status == 200, conn.resp_body

      account = body(send_json(:get, "/v1/savingsaccounts/#{id}?associations=transactions"))
      assert account["status"]["value"] == "Closed"
      assert account["summary"]["accountBalance"] == 0
      assert length(account["transactions"]) == 2

      # a closed account takes no more money
      assert money(id, "deposit", 1).status == 400
    end

    test "undoing a deposit that money was taken out of is refused" do
      id = live_account()
      tx = body(money(id, "deposit", 40))["resourceId"]
      assert money(id, "withdrawal", 30).status == 200

      conn = send_json(:post, "/v1/savingsaccounts/#{id}/transactions/#{tx}?command=undo", %{})
      assert conn.status == 400

      assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
               "validation.msg.savingsaccount.undotransaction.results.in.balance.going.negative"
    end
  end
end
