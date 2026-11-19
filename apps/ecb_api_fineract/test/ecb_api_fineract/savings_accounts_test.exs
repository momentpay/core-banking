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
            %{"charges" => [%{"chargeId" => 1}]},
            %{"lienAllowed" => true},
            %{"withHoldTax" => true}
          ] do
        conn = apply_for(client_id, product_id, extra)
        assert conn.status == 403, conn.resp_body

        assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
                 "error.msg.savingsaccount.feature.not.supported.yet"
      end
    end

    test "activating an account with an opening balance to deposit is refused" do
      id = approved_account(%{"minRequiredOpeningBalance" => 100})

      conn = command(id, "activate", %{"activatedOnDate" => today()})
      assert conn.status == 403

      assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
               "error.msg.savingsaccount.feature.not.supported.yet"

      # and the account stays approved
      assert body(send_json(:get, "/v1/savingsaccounts/#{id}"))["status"]["value"] == "Approved"
    end

    test "the commands for interest, officers and blocks are refused, not taken for unknown" do
      id = approved_account()

      for name <- ["calculateInterest", "postInterest", "assignSavingsOfficer", "block"] do
        conn = command(id, name, %{})
        assert conn.status == 403, name

        assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
                 "error.msg.savingsaccount.feature.not.supported.yet"
      end
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
end
