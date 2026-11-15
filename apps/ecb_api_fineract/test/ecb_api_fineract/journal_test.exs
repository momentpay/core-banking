defmodule ECBApiFineract.JournalTest do
  @moduledoc """
  Journal entries beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions,
  that a refused posting leaves nothing behind, that a reversal cancels its posting, and that running
  balances add up.
  """
  use ECBApiFineract.ApiCase

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp account(code, type, extra \\ %{}) do
    conn =
      send_json(
        :post,
        "/v1/glaccounts",
        Map.merge(
          %{
            "name" => "Account #{code}",
            "glCode" => code,
            "manualEntriesAllowed" => true,
            "type" => type,
            "usage" => 1
          },
          extra
        )
      )

    body(conn)["resourceId"]
  end

  defp posting(date, debits, credits, extra \\ %{}) do
    Map.merge(
      %{
        "officeId" => 1,
        "currencyCode" => "USD",
        "transactionDate" => date,
        "dateFormat" => "yyyy-MM-dd",
        "locale" => "en",
        "debits" =>
          Enum.map(debits, fn {id, amount} -> %{"glAccountId" => id, "amount" => amount} end),
        "credits" =>
          Enum.map(credits, fn {id, amount} -> %{"glAccountId" => id, "amount" => amount} end)
      },
      extra
    )
  end

  defp post!(body, auth \\ admin()) do
    conn = send_json(:post, "/v1/journalentries", body, auth)
    assert conn.status == 200, conn.resp_body
    body(conn)["transactionId"]
  end

  defp entries(query \\ ""), do: body(send_json(:get, "/v1/journalentries" <> query))["pageItems"]

  defp reverse!(transaction) do
    conn = send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{})
    assert conn.status == 200, conn.resp_body
    body(conn)["transactionId"]
  end

  # what an account has had debited less what it has had credited, reversals included
  defp net(account_id) do
    Enum.reduce(entries("?glAccountId=#{account_id}"), 0, fn entry, sum ->
      if entry["entryType"]["value"] == "DEBIT",
        do: sum + entry["amount"],
        else: sum - entry["amount"]
    end)
  end

  defp setup_accounts(_context) do
    %{cash: account("1000", 1), payables: account("2000", 2), fees: account("4000", 4)}
  end

  setup :setup_accounts

  describe "posting" do
    test "a refused posting leaves nothing behind", %{cash: cash, payables: payables} do
      locked = account("1100", 1, %{"manualEntriesAllowed" => false})

      # the debit line is written before the credit line is found to be refused, then rolled back
      conn =
        send_json(
          :post,
          "/v1/journalentries",
          posting("2025-03-01", [{cash, 10}], [{locked, 10}])
        )

      assert conn.status == 403
      assert entries() == []

      assert send_json(
               :post,
               "/v1/journalentries",
               posting("2025-03-01", [{cash, 10}], [{payables, 10}])
             ).status ==
               200

      assert length(entries()) == 2
    end

    test "every posting gets a transaction id of its own, even in a rush", %{
      cash: cash,
      payables: payables
    } do
      ids = for _ <- 1..20, do: post!(posting("2025-03-01", [{cash, 1}], [{payables, 1}]))

      assert length(Enum.uniq(ids)) == 20
    end

    test "one payment detail serves all the lines of a posting and its reversal keeps it", %{
      cash: cash,
      payables: payables
    } do
      transaction =
        post!(
          posting("2025-03-01", [{cash, 5}], [{payables, 5}], %{
            "paymentTypeId" => 1,
            "receiptNumber" => "R-1"
          })
        )

      assert TenantRepo.aggregate("m_payment_detail", :count) == 1

      conn = send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{})
      assert conn.status == 200
      assert TenantRepo.aggregate("m_payment_detail", :count) == 1

      detailed = body(send_json(:get, "/v1/journalentries?transactionDetails=true"))["pageItems"]
      assert length(detailed) == 4

      assert Enum.all?(
               detailed,
               &(&1["transactionDetails"]["paymentDetails"]["receiptNumber"] == "R-1")
             )
    end

    test "an amount is kept to the cent and its places are not rounded away", %{
      cash: cash,
      payables: payables
    } do
      post!(posting("2025-03-01", [{cash, 0.1}, {cash, 0.2}], [{payables, 0.3}]))

      assert Enum.map(entries(), & &1["amount"]) == [0.1, 0.2, 0.3]
    end
  end

  describe "reversal" do
    test "cancels the posting: every account is back where it was", %{
      cash: cash,
      payables: payables,
      fees: fees
    } do
      transaction =
        post!(posting("2025-03-01", [{cash, 70}, {cash, 30}], [{fees, 60}, {payables, 40}]))

      conn =
        send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{
          "comments" => "oops"
        })

      assert conn.status == 200

      assert net(cash) == 0
      assert net(payables) == 0
      assert net(fees) == 0
      assert Enum.all?(Enum.take(entries(), 4), & &1["reversed"])
    end

    test "a reversal is itself a posting that can be reversed", %{cash: cash, payables: payables} do
      transaction = post!(posting("2025-03-01", [{cash, 50}], [{payables, 50}]))
      reversal = reverse!(transaction)

      assert net(cash) == 0
      reverse!(reversal)
      assert net(cash) == 50
    end

    test "is refused once the books are closed up to the posting's date", %{
      cash: cash,
      payables: payables
    } do
      transaction = post!(posting("2025-03-01", [{cash, 50}], [{payables, 50}]))

      closure = %{
        "officeId" => 1,
        "closingDate" => "2025-03-01",
        "dateFormat" => "yyyy-MM-dd",
        "locale" => "en"
      }

      assert send_json(:post, "/v1/glclosures", closure).status == 200

      conn = send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{})
      assert conn.status == 403

      assert body(conn)["errors"] |> hd() |> Map.get("userMessageGlobalisationCode") ==
               "error.msg.glJournalEntry.invalid.accounting.closed"
    end
  end

  describe "running balances" do
    test "an entry's balance is the balance of its account after it, by date then id", %{
      cash: cash,
      payables: payables,
      fees: fees
    } do
      post!(posting("2025-03-02", [{cash, 100}], [{fees, 100}]))
      post!(posting("2025-03-01", [{cash, 40}], [{payables, 40}]))
      post!(posting("2025-03-03", [{payables, 10}], [{cash, 10}]))

      assert send_json(:post, "/v1/journalentries?command=updateRunningBalance", %{}).status ==
               200

      cash_balances =
        entries("?glAccountId=#{cash}&runningBalance=true")
        |> Enum.map(
          &{&1["transactionDate"], &1["organizationRunningBalance"], &1["runningBalanceComputed"]}
        )

      # asset: 40 (debit, 1 March), 140 (debit, 2 March), 130 (credit, 3 March)
      assert cash_balances == [
               {[2025, 3, 1], 40.0, true},
               {[2025, 3, 2], 140.0, true},
               {[2025, 3, 3], 130.0, true}
             ]

      payable_balances =
        entries("?glAccountId=#{payables}&runningBalance=true")
        |> Enum.map(& &1["organizationRunningBalance"])

      # liability: 40 (credit), then 30 (a debit of 10 lessens it): 30.0
      assert payable_balances == [40.0, 30.0]
    end

    test "an office's balance leaves the organisation's alone and leaves the entries waiting", %{
      cash: cash,
      payables: payables
    } do
      post!(posting("2025-03-01", [{cash, 25}], [{payables, 25}]))

      assert send_json(:post, "/v1/journalentries?command=updateRunningBalance", %{
               "officeId" => 1
             }).status ==
               200

      [first | _] = entries("?runningBalance=true")
      assert first["officeRunningBalance"] == 25.0
      assert first["organizationRunningBalance"] == 0.0
      assert first["runningBalanceComputed"] == false
    end

    test "only entries after the last calculated one are worked out again, and earlier ones are kept",
         %{
           cash: cash,
           payables: payables
         } do
      post!(posting("2025-03-01", [{cash, 25}], [{payables, 25}]))
      send_json(:post, "/v1/journalentries?command=updateRunningBalance", %{})
      post!(posting("2025-03-02", [{cash, 5}], [{payables, 5}]))
      send_json(:post, "/v1/journalentries?command=updateRunningBalance", %{})

      balances =
        entries("?glAccountId=#{cash}&runningBalance=true")
        |> Enum.map(& &1["organizationRunningBalance"])

      assert balances == [25.0, 30.0]
    end
  end

  describe "ordering" do
    test "can be by amount, either way", %{cash: cash, payables: payables} do
      post!(posting("2025-03-01", [{cash, 30}], [{payables, 30}]))
      post!(posting("2025-03-01", [{cash, 10}], [{payables, 10}]))
      post!(posting("2025-03-01", [{cash, 20}], [{payables, 20}]))

      ascending = entries("?orderBy=amount&sortOrder=asc") |> Enum.map(& &1["amount"])
      descending = entries("?orderBy=amount&sortOrder=desc") |> Enum.map(& &1["amount"])

      assert ascending == Enum.sort(ascending)
      assert descending == Enum.sort(descending, :desc)
    end

    test "a column that does not exist is a server error, as in Fineract" do
      assert send_json(:get, "/v1/journalentries?orderBy=bogus").status == 500
      assert send_json(:get, "/v1/journalentries?orderBy=id&sortOrder=sideways").status == 500
    end
  end

  describe "permissions" do
    test "reading needs READ_JOURNALENTRY", %{cash: cash, payables: payables} do
      post!(posting("2025-03-01", [{cash, 1}], [{payables, 1}]))

      reader = make_user("je-reader", ["READ_JOURNALENTRY"])
      assert send_json(:get, "/v1/journalentries", nil, reader).status == 200
      assert send_json(:get, "/v1/journalentries/1", nil, reader).status == 200

      nobody = make_user("je-nobody", ["READ_OFFICE"])
      assert send_json(:get, "/v1/journalentries", nil, nobody).status == 403

      assert send_json(:get, "/v1/journalentries/openingbalance?officeId=1", nil, nobody).status ==
               403
    end

    test "posting, reversing and balancing each need their own permission", %{
      cash: cash,
      payables: payables
    } do
      transaction = post!(posting("2025-03-01", [{cash, 1}], [{payables, 1}]))
      body = posting("2025-03-02", [{cash, 1}], [{payables, 1}])

      reader = make_user("je-reader", ["READ_JOURNALENTRY"])
      assert send_json(:post, "/v1/journalentries", body, reader).status == 403

      assert send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{}, reader).status ==
               403

      assert send_json(:post, "/v1/journalentries?command=updateRunningBalance", %{}, reader).status ==
               403

      assert send_json(:post, "/v1/journalentries?command=defineOpeningBalance", body, reader).status ==
               403

      poster = make_user("je-poster", ["CREATE_JOURNALENTRY"])
      assert send_json(:post, "/v1/journalentries", body, poster).status == 200

      assert send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{}, poster).status ==
               403

      reverser = make_user("je-reverser", ["REVERSE_JOURNALENTRY"])

      assert send_json(:post, "/v1/journalentries/#{transaction}?command=reverse", %{}, reverser).status ==
               200
    end

    test "provisioning entries need only a signed-in user" do
      nobody = make_user("je-anyone", ["READ_OFFICE"])

      assert send_json(:get, "/v1/journalentries/provisioning?entryId=1", nil, nobody).status ==
               200
    end
  end

  describe "accounts that were posted to" do
    test "cannot be deleted", %{cash: cash, payables: payables} do
      post!(posting("2025-03-01", [{cash, 1}], [{payables, 1}]))

      assert send_json(:delete, "/v1/glaccounts/#{cash}").status == 403
    end
  end
end
