defmodule ECBApiFineract.RatesTest do
  @moduledoc """
  Rates and floating rates beyond the responses recorded from Fineract (those are in `ScenariosTest`):
  permissions, the periods a floating-rate update replaces, and the audit trail of writes.
  """
  use ECBApiFineract.ApiCase

  import Ecto.Query

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp floating(extra) do
    conn = send_json(:post, "/v1/floatingrates", Map.merge(%{"name" => "Series"}, extra))
    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp period(date, rate), do: %{"fromDate" => date, "interestRate" => rate}

  describe "rates" do
    test "reading needs READ_RATE and each write its own permission" do
      request = %{"name" => "R", "percentage" => 5, "productApply" => 1, "locale" => "en"}

      assert send_json(:post, "/v1/rates", request, make_user("rate-none", [])).status == 403
      assert send_json(:get, "/v1/rates", nil, make_user("rate-none-2", [])).status == 403

      assert send_json(:get, "/v1/rates", nil, make_user("rate-reader", ["READ_RATE"])).status ==
               200

      creator = make_user("rate-creator", ["CREATE_RATE"])
      created = send_json(:post, "/v1/rates", request, creator)
      assert created.status == 200
      id = body(created)["resourceId"]

      change = %{"percentage" => 6, "locale" => "en"}
      assert send_json(:put, "/v1/rates/#{id}", change, creator).status == 403

      updater = make_user("rate-updater", ["UPDATE_RATE"])
      assert send_json(:put, "/v1/rates/#{id}", change, updater).status == 200
    end

    test "a kind of product other than a loan is stored and shown as invalid" do
      id =
        body(
          send_json(:post, "/v1/rates", %{
            "name" => "Odd",
            "percentage" => 1,
            "productApply" => 7,
            "locale" => "en"
          })
        )["resourceId"]

      shown = body(send_json(:get, "/v1/rates/#{id}"))

      assert shown["productApply"] == %{
               "id" => 0,
               "code" => "rateAppliesTo.invalid",
               "value" => "Invalid"
             }
    end
  end

  describe "floating rates" do
    test "any signed-in user may read them, but writing needs a permission" do
      nobody = make_user("floating-none", [])
      assert send_json(:get, "/v1/floatingrates", nil, nobody).status == 200
      assert send_json(:post, "/v1/floatingrates", %{"name" => "X"}, nobody).status == 403

      creator = make_user("floating-creator", ["CREATE_FLOATINGRATE"])
      created = send_json(:post, "/v1/floatingrates", %{"name" => "X"}, creator)
      assert created.status == 200
      id = body(created)["resourceId"]

      assert send_json(:put, "/v1/floatingrates/#{id}", %{"name" => "Y"}, creator).status == 403

      updater = make_user("floating-updater", ["UPDATE_FLOATINGRATE"])
      assert send_json(:put, "/v1/floatingrates/#{id}", %{"name" => "Y"}, updater).status == 200
    end

    test "an update replaces only the periods that have not started" do
      id = floating(%{"ratePeriods" => [period("2099-01-01", 1)]})

      # that period has now started
      TenantRepo.update_all(
        from(p in "m_floating_rates_periods", where: p.floating_rates_id == ^id),
        set: [from_date: ~D[2020-01-01]]
      )

      assert send_json(:put, "/v1/floatingrates/#{id}", %{
               "ratePeriods" => [period("2099-01-01", 2)]
             }).status == 200

      active =
        TenantRepo.all(
          from(p in "m_floating_rates_periods",
            where: p.floating_rates_id == ^id and p.is_active == true,
            order_by: p.from_date,
            select: p.interest_rate
          )
        )

      assert Enum.map(active, &Decimal.to_float/1) == [1.0, 2.0]

      assert send_json(:put, "/v1/floatingrates/#{id}", %{
               "ratePeriods" => [period("2099-02-01", 3)]
             }).status == 200

      active =
        TenantRepo.all(
          from(p in "m_floating_rates_periods",
            where: p.floating_rates_id == ^id and p.is_active == true,
            order_by: p.from_date,
            select: p.interest_rate
          )
        )

      assert Enum.map(active, &Decimal.to_float/1) == [1.0, 3.0]
    end

    test "a second base lending rate is refused" do
      floating(%{
        "name" => "Base",
        "isBaseLendingRate" => true,
        "ratePeriods" => [period("2099-01-01", 1)]
      })

      refused =
        send_json(:post, "/v1/floatingrates", %{"name" => "Other", "isBaseLendingRate" => true})

      assert refused.status == 400
    end

    test "a name already taken is a data-integrity error on create" do
      floating(%{"name" => "Taken"})
      refused = send_json(:post, "/v1/floatingrates", %{"name" => "Taken"})

      assert refused.status == 403

      assert body(refused)["userMessageGlobalisationCode"] ==
               "error.msg.floatingrates.unknown.data.integrity.issue"
    end

    test "writes are recorded as commands" do
      floating(%{"name" => "Audited"})

      assert [%{entity_name: "FLOATINGRATE", action_name: "CREATE"}] =
               TenantRepo.all(
                 from(c in "m_portfolio_command_source",
                   where: c.entity_name == "FLOATINGRATE",
                   select: %{entity_name: c.entity_name, action_name: c.action_name}
                 )
               )
    end
  end
end
