defmodule ECBApiFineract.TaxesTest do
  @moduledoc """
  Tax components and groups beyond the responses recorded from Fineract (those are in `ScenariosTest`):
  components that carry accounts (which Fineract cannot show), the history a percentage change leaves,
  group totals, and permissions.
  """
  use ECBApiFineract.ApiCase

  import Ecto.Query

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  @dates %{"dateFormat" => "yyyy-MM-dd", "locale" => "en"}

  defp account(code, type, usage \\ 1) do
    body(
      send_json(:post, "/v1/glaccounts", %{
        "name" => "Account #{code}",
        "glCode" => code,
        "manualEntriesAllowed" => true,
        "type" => type,
        "usage" => usage
      })
    )["resourceId"]
  end

  defp component(extra) do
    request =
      %{"name" => "VAT", "percentage" => 10, "startDate" => "2025-01-01"}
      |> Map.merge(extra)
      |> Map.merge(@dates)

    conn = send_json(:post, "/v1/taxes/component", request)
    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp group(name, components) do
    items = Enum.map(components, &%{"taxComponentId" => &1, "startDate" => "2025-01-01"})

    conn =
      send_json(
        :post,
        "/v1/taxes/group",
        Map.merge(%{"name" => name, "taxComponents" => items}, @dates)
      )

    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp raise_to(id, percentage, start),
    do:
      send_json(
        :put,
        "/v1/taxes/component/#{id}",
        Map.merge(%{"percentage" => percentage, "startDate" => start}, @dates)
      )

  defp history,
    do:
      TenantRepo.all(
        from(h in "m_tax_component_history",
          order_by: h.id,
          select: %{percentage: h.percentage, start_date: h.start_date, end_date: h.end_date}
        )
      )

  describe "a component with accounts" do
    test "shows the accounts and their types, which Fineract fails to show" do
      payable = account("2100", 2)
      expense = account("5100", 5)

      id =
        component(%{
          "debitAccountType" => 5,
          "debitAccountId" => expense,
          "creditAccountType" => 2,
          "creditAccountId" => payable
        })

      shown = body(send_json(:get, "/v1/taxes/component/#{id}"))

      assert shown["debitAccountType"] == %{
               "id" => 5,
               "code" => "accountType.expense",
               "value" => "EXPENSE"
             }

      assert shown["creditAccountType"]["value"] == "LIABILITY"
      assert shown["debitAccount"]["id"] == expense
      assert shown["creditAccount"]["glCode"] == "2100"

      assert [listed] = body(send_json(:get, "/v1/taxes/component"))
      assert listed["id"] == id
    end

    test "refuses an account that is a header or of another type" do
      header = account("2", 2, 2)
      asset = account("1100", 1)

      credit = %{
        "name" => "X",
        "percentage" => 1,
        "creditAccountType" => 2,
        "creditAccountId" => header
      }

      assert send_json(:post, "/v1/taxes/component", Map.merge(credit, @dates)).status == 400

      debit = %{
        "name" => "X",
        "percentage" => 1,
        "debitAccountType" => 5,
        "debitAccountId" => asset
      }

      assert send_json(:post, "/v1/taxes/component", Map.merge(debit, @dates)).status == 400
    end
  end

  describe "changing a percentage" do
    test "keeps the old rate in the history with the dates it applied" do
      id = component(%{"percentage" => 10})

      assert raise_to(id, 12, "2099-01-01").status == 200

      [first] = history()
      assert Decimal.equal?(first.percentage, 10)
      assert first.start_date == ~D[2025-01-01]
      assert first.end_date == ~D[2099-01-01]

      assert raise_to(id, 15, "2100-01-01").status == 200
      assert length(history()) == 2
    end

    test "a component that is in a group cannot be raised past what the group allows" do
      big = component(%{"name" => "Big", "percentage" => 90})
      small = component(%{"name" => "Small", "percentage" => 5})
      group("Pair", [big, small])

      assert raise_to(big, 99, "2099-01-01").status == 400
      assert raise_to(big, 95, "2099-01-01").status == 200
    end

    test "a component in two groups may be at 60 per cent in each" do
      a = component(%{"name" => "A", "percentage" => 10})
      group("One", [a])
      group("Two", [a])

      assert raise_to(a, 60, "2099-01-01").status == 200
    end
  end

  describe "a group" do
    test "can be renamed without sending its components, where Fineract crashes" do
      a = component(%{})
      id = group("Plain", [a])

      assert send_json(:put, "/v1/taxes/group/#{id}", %{"name" => "Renamed"}).status == 200
      assert body(send_json(:get, "/v1/taxes/group/#{id}"))["name"] == "Renamed"

      assert send_json(:put, "/v1/taxes/group/#{id}", %{}).status == 200
      assert send_json(:post, "/v1/taxes/group", %{}).status == 400
    end

    test "cannot be re-dated once a charge uses it" do
      a = component(%{})
      id = group("Used", [a])

      assert body(send_json(:get, "/v1/taxes/group/#{id}?template=true"))["groupEditable"] == true

      TenantRepo.query!(
        "INSERT INTO m_charge (id, name, currency_code, charge_applies_to_enum, charge_time_enum, charge_calculation_enum, charge_payment_mode_enum, amount, is_penalty, is_active, is_deleted, tax_group_id) VALUES (1, 'C', 'USD', 1, 1, 1, 0, 1, false, true, false, $1)",
        [id]
      )

      assert body(send_json(:get, "/v1/taxes/group/#{id}?template=true"))["groupEditable"] ==
               false

      [association] = body(send_json(:get, "/v1/taxes/group/#{id}"))["taxAssociations"]
      change = %{"taxComponents" => [%{"id" => association["id"], "startDate" => "2099-01-01"}]}

      refused = send_json(:put, "/v1/taxes/group/#{id}", Map.merge(change, @dates))
      assert refused.status == 400

      assert hd(body(refused)["errors"])["userMessageGlobalisationCode"] ==
               "validation.msg.tax.group.startDate.cannot.be.modified.for.linked.tax.group"

      TenantRepo.query!("DELETE FROM m_charge")
    end

    test "an association can be ended" do
      a = component(%{})
      id = group("Ends", [a])
      [association] = body(send_json(:get, "/v1/taxes/group/#{id}"))["taxAssociations"]

      change = %{"taxComponents" => [%{"id" => association["id"], "endDate" => "2099-01-01"}]}
      ended = send_json(:put, "/v1/taxes/group/#{id}", Map.merge(change, @dates))

      assert ended.status == 200

      assert body(ended)["changes"]["modifiedComponents"] == [
               %{"endDate" => [2099, 1, 1], "taxComponentId" => a}
             ]

      [shown] = body(send_json(:get, "/v1/taxes/group/#{id}"))["taxAssociations"]
      assert shown["endDate"] == "2099-01-01"
    end
  end

  describe "permissions" do
    test "reading needs READ_TAXCOMPONENT or READ_TAXGROUP, writing the matching permission" do
      request = Map.merge(%{"name" => "X", "percentage" => 1}, @dates)

      reader = make_user("tax-reader", ["READ_TAXCOMPONENT"])
      assert send_json(:get, "/v1/taxes/component", nil, reader).status == 200
      assert send_json(:get, "/v1/taxes/component/template", nil, reader).status == 200
      assert send_json(:get, "/v1/taxes/group", nil, reader).status == 403
      assert send_json(:post, "/v1/taxes/component", request, reader).status == 403

      creator = make_user("tax-creator", ["CREATE_TAXCOMPONENT"])
      assert send_json(:post, "/v1/taxes/component", request, creator).status == 200
      assert send_json(:put, "/v1/taxes/component/1", %{"name" => "Y"}, creator).status == 403
    end
  end
end
