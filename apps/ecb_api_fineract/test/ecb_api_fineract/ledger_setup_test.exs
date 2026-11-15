defmodule ECBApiFineract.LedgerSetupTest do
  @moduledoc """
  Financial-activity mappings and accounting closures beyond the responses recorded from Fineract (those
  are in `ScenariosTest`): permissions, the order closures must be deleted in, and what a mapping
  protects.
  """
  use ECBApiFineract.ApiCase

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp account(code, type) do
    conn =
      send_json(:post, "/v1/glaccounts", %{
        "name" => "Account #{code}",
        "glCode" => code,
        "manualEntriesAllowed" => true,
        "type" => type,
        "usage" => 1
      })

    body(conn)["resourceId"]
  end

  defp closure(date, extra \\ %{}) do
    send_json(
      :post,
      "/v1/glclosures",
      Map.merge(
        %{"officeId" => 1, "closingDate" => date, "dateFormat" => "yyyy-MM-dd", "locale" => "en"},
        extra
      )
    )
  end

  defp map(activity, account),
    do: %{"financialActivityId" => activity, "glAccountId" => account}

  defp office_body,
    do: %{
      "name" => "Branch",
      "parentId" => 1,
      "openingDate" => "2020-01-01",
      "dateFormat" => "yyyy-MM-dd",
      "locale" => "en"
    }

  describe "financial activity mappings" do
    test "a mapping keeps its account from being deleted, and deleting the mapping frees it" do
      cash = account("1000", 1)

      mapping =
        body(send_json(:post, "/v1/financialactivityaccounts", map(101, cash)))["resourceId"]

      refused = send_json(:delete, "/v1/glaccounts/#{cash}")
      assert refused.status == 403
      assert body(refused)["userMessageGlobalisationCode"] == "error.msg.data.integrity.issue"

      assert send_json(:delete, "/v1/financialactivityaccounts/#{mapping}").status == 200
      assert send_json(:delete, "/v1/glaccounts/#{cash}").status == 200
    end

    test "the template offers only enabled detail accounts, grouped by type" do
      account("1000", 1)
      account("2000", 2)

      send_json(:post, "/v1/glaccounts", %{
        "name" => "Header",
        "glCode" => "1",
        "type" => 1,
        "usage" => 2
      })

      options =
        body(send_json(:get, "/v1/financialactivityaccounts/template"))["glAccountOptions"]

      assert Map.keys(options) |> Enum.sort() == [
               "assetAccountOptions",
               "liabilityAccountOptions"
             ]

      assert Enum.map(options["assetAccountOptions"], & &1["glCode"]) == ["1000"]
    end

    test "reading needs READ_FINANCIALACTIVITYACCOUNT and writing the matching permission" do
      cash = account("1000", 1)

      reader = make_user("faa-reader", ["READ_FINANCIALACTIVITYACCOUNT"])
      assert send_json(:get, "/v1/financialactivityaccounts", nil, reader).status == 200

      assert send_json(:post, "/v1/financialactivityaccounts", map(101, cash), reader).status ==
               403

      nobody = make_user("faa-nobody", ["READ_OFFICE"])
      assert send_json(:get, "/v1/financialactivityaccounts/template", nil, nobody).status == 403
    end

    test "a refused mapping leaves the existing one as it was" do
      cash = account("1000", 1)
      payable = account("2000", 2)
      send_json(:post, "/v1/financialactivityaccounts", map(101, cash))

      refused = send_json(:post, "/v1/financialactivityaccounts", map(100, payable))
      assert refused.status == 403

      [row] = body(send_json(:get, "/v1/financialactivityaccounts"))
      assert row["financialActivityData"]["name"] == "cashAtMainVault"
    end
  end

  describe "accounting closures" do
    test "only the latest closure of an office can be deleted, so they are removed newest first" do
      first = body(closure("2025-01-31"))["resourceId"]
      second = body(closure("2025-02-28"))["resourceId"]

      assert send_json(:delete, "/v1/glclosures/#{first}").status == 403
      assert send_json(:delete, "/v1/glclosures/#{second}").status == 200
      assert send_json(:delete, "/v1/glclosures/#{first}").status == 200
      assert body(send_json(:get, "/v1/glclosures")) == []
    end

    test "a closure of one office does not hold back another office's dates" do
      office = body(send_json(:post, "/v1/offices", office_body()))["resourceId"]

      assert closure("2025-03-31").status == 200
      assert closure("2025-01-31", %{"officeId" => office}).status == 200

      assert send_json(:get, "/v1/glclosures?officeId=#{office}")
             |> body()
             |> Enum.map(& &1["closingDate"]) == ["2025-01-31"]
    end

    test "the latest closing date is the date up to which an office is closed" do
      closure("2025-01-31")
      closure("2025-02-28")

      assert ECBLedger.Closures.closed_until(1) == ~D[2025-02-28]
      assert ECBLedger.Closures.closed_until(2) == nil
    end

    test "a closure remembers who made and who last changed it" do
      id = body(closure("2025-01-31"))["resourceId"]
      other = make_user("closer", ["UPDATE_GLCLOSURE"])

      assert send_json(:put, "/v1/glclosures/#{id}", %{"comments" => "Checked"}, other).status ==
               200

      shown = body(send_json(:get, "/v1/glclosures/#{id}"))
      assert shown["createdByUsername"] == "mifos"
      assert shown["lastUpdatedByUsername"] == "apitest-closer"
    end

    test "reading needs READ_GLCLOSURE and writing the matching permission" do
      reader = make_user("closure-reader", ["READ_GLCLOSURE"])
      assert send_json(:get, "/v1/glclosures", nil, reader).status == 200

      denied =
        send_json(
          :post,
          "/v1/glclosures",
          %{
            "officeId" => 1,
            "closingDate" => "2025-01-31",
            "dateFormat" => "yyyy-MM-dd",
            "locale" => "en"
          },
          reader
        )

      assert denied.status == 403

      assert send_json(:get, "/v1/glclosures", nil, make_user("nobody", ["READ_OFFICE"])).status ==
               403
    end
  end
end
