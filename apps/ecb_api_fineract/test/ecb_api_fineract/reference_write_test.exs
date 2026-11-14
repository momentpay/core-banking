defmodule ECBApiFineract.ReferenceWriteTest do
  @moduledoc """
  Funds, payment types and staff beyond the responses recorded from Fineract (those are in
  `ScenariosTest`): duplicates, the checks E-CoreBank adds where Fineract 1.16 answers HTTP 500, and
  who may write.
  """
  use ECBApiFineract.ApiCase

  defp send_json(method, path, body, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  describe "funds" do
    test "a name or external id already in use is refused with its own message" do
      assert send_json(:post, "/v1/funds", %{"name" => "Equity", "externalId" => "E1"}).status ==
               200

      same_name = send_json(:post, "/v1/funds", %{"name" => "Equity"})
      assert same_name.status == 403
      assert body(same_name)["userMessageGlobalisationCode"] == "error.msg.fund.duplicate.name"

      same_external = send_json(:post, "/v1/funds", %{"name" => "Debt", "externalId" => "E1"})
      assert same_external.status == 403

      assert body(same_external)["userMessageGlobalisationCode"] ==
               "error.msg.fund.duplicate.externalId"
    end

    test "renaming a fund to a name in use is refused and changes nothing" do
      send_json(:post, "/v1/funds", %{"name" => "Equity"})
      send_json(:post, "/v1/funds", %{"name" => "Debt"})

      conn = send_json(:put, "/v1/funds/2", %{"name" => "Equity"})
      assert conn.status == 403
      assert body(call(:get, "/api/v1/funds/2", auth: admin()))["name"] == "Debt"
    end

    test "a user without CREATE_FUND is refused" do
      reader = make_user("fund-reader", ["READ_FUND"])
      assert send_json(:post, "/v1/funds", %{"name" => "No"}, reader).status == 403
      assert body(call(:get, "/api/v1/funds", auth: admin())) == []
    end
  end

  describe "payment types" do
    test "a name is required, and unknown parameters are refused (where Fineract 1.16 answers 500)" do
      no_name = send_json(:post, "/v1/paymenttypes", %{})
      assert no_name.status == 400
      assert [%{"parameterName" => "name"}] = body(no_name)["errors"]

      unknown = send_json(:post, "/v1/paymenttypes", %{"name" => "Cheque", "bogus" => 1})
      assert unknown.status == 400

      assert [%{"userMessageGlobalisationCode" => "error.msg.parameter.unsupported"}] =
               body(unknown)["errors"]
    end

    test "limits are checked" do
      conn =
        send_json(:post, "/v1/paymenttypes", %{
          "name" => "X",
          "position" => -1,
          "description" => String.duplicate("d", 501)
        })

      assert conn.status == 400

      assert body(conn)["errors"] |> Enum.map(& &1["parameterName"]) |> Enum.sort() == [
               "description",
               "position"
             ]
    end

    test "an update changes only what it sends" do
      %{"resourceId" => id} =
        send_json(:post, "/v1/paymenttypes", %{
          "name" => "Cheque",
          "description" => "d",
          "isCashPayment" => false,
          "position" => 4
        })
        |> body()

      assert send_json(:put, "/v1/paymenttypes/#{id}", %{"name" => "Cheque 2"}).status == 200

      assert %{
               "name" => "Cheque 2",
               "description" => "d",
               "position" => 4,
               "isCashPayment" => false
             } =
               call(:get, "/api/v1/paymenttypes/#{id}", auth: admin()) |> body()
    end

    test "a payment type that is in use cannot be deleted" do
      %{"resourceId" => id} =
        send_json(:post, "/v1/paymenttypes", %{"name" => "Cheque", "position" => 1}) |> body()

      ECBPlatform.TenantRepo.query!("""
      CREATE TABLE IF NOT EXISTS ecb_test_refers_payment_type (payment_type_id integer REFERENCES m_payment_type(id))
      """)

      ECBPlatform.TenantRepo.query!("INSERT INTO ecb_test_refers_payment_type VALUES ($1)", [id])

      try do
        conn = call(:delete, "/api/v1/paymenttypes/#{id}", auth: admin())
        assert conn.status == 403

        assert body(conn)["userMessageGlobalisationCode"] ==
                 "error.msg.payment.type.association.exist"
      after
        # the tenant database is not rolled back between tests: leave nothing that refers to the row
        ECBPlatform.TenantRepo.query!("DROP TABLE ecb_test_refers_payment_type")
      end
    end
  end

  describe "staff" do
    test "the display name follows the name, and changes on update" do
      send_json(:post, "/v1/staff", %{
        "officeId" => 1,
        "firstname" => "Ada",
        "lastname" => "Lovelace"
      })

      send_json(:put, "/v1/staff/1", %{"lastname" => "King"})

      assert %{"displayName" => "King, Ada"} =
               call(:get, "/api/v1/staff/1", auth: admin()) |> body()
    end

    test "the same display name or external id twice is refused with its own message" do
      send_json(:post, "/v1/staff", %{
        "officeId" => 1,
        "firstname" => "Ada",
        "lastname" => "Lovelace",
        "externalId" => "A"
      })

      same_name =
        send_json(:post, "/v1/staff", %{
          "officeId" => 1,
          "firstname" => "Ada",
          "lastname" => "Lovelace"
        })

      assert same_name.status == 403

      assert body(same_name)["userMessageGlobalisationCode"] ==
               "error.msg.staff.duplicate.displayName"

      same_external =
        send_json(:post, "/v1/staff", %{
          "officeId" => 1,
          "firstname" => "Bo",
          "lastname" => "B",
          "externalId" => "A"
        })

      assert same_external.status == 403

      assert body(same_external)["userMessageGlobalisationCode"] ==
               "error.msg.staff.duplicate.externalId"
    end

    test "all the missing mandatory values are reported together, by their path" do
      conn = send_json(:post, "/v1/staff", %{})

      assert conn.status == 400

      assert body(conn)["errors"] |> Enum.map(& &1["parameterName"]) ==
               [
                 "createStaff.request.officeId",
                 "createStaff.request.firstname",
                 "createStaff.request.lastname"
               ]
    end

    test "a bad phone number is refused" do
      conn =
        send_json(:post, "/v1/staff", %{
          "officeId" => 1,
          "firstname" => "A",
          "lastname" => "B",
          "mobileNo" => "abc"
        })

      assert conn.status == 400
      assert [%{"parameterName" => "createStaff.request.mobileNo"}] = body(conn)["errors"]
    end

    test "staff can be moved to another office" do
      send_json(:post, "/v1/offices", %{
        "name" => "Nairobi",
        "parentId" => 1,
        "openingDate" => "01 March 2020",
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en"
      })

      send_json(:post, "/v1/staff", %{
        "officeId" => 1,
        "firstname" => "Ada",
        "lastname" => "Lovelace"
      })

      conn = send_json(:put, "/v1/staff/1", %{"officeId" => 2})
      assert body(conn) == %{"officeId" => 2, "resourceId" => 1, "changes" => %{"officeId" => 2}}
      assert %{"officeName" => "Nairobi"} = call(:get, "/api/v1/staff/1", auth: admin()) |> body()
    end
  end

  describe "codes" do
    test "a duplicate name, and a duplicate value label within a code, are refused" do
      %{"resourceId" => id} = send_json(:post, "/v1/codes", %{"name" => "Region"}) |> body()
      assert send_json(:post, "/v1/codes", %{"name" => "Region"}).status == 403

      assert send_json(:post, "/v1/codes/#{id}/codevalues", %{"name" => "North"}).status == 200
      dup = send_json(:post, "/v1/codes/#{id}/codevalues", %{"name" => "North"})
      assert dup.status == 403
      assert body(dup)["userMessageGlobalisationCode"] == "error.msg.code.value.duplicate.label"

      # the same label under another code is fine
      %{"resourceId" => other} = send_json(:post, "/v1/codes", %{"name" => "Area"}) |> body()
      assert send_json(:post, "/v1/codes/#{other}/codevalues", %{"name" => "North"}).status == 200
    end

    test "deleting a code takes its values with it" do
      %{"resourceId" => id} = send_json(:post, "/v1/codes", %{"name" => "Region"}) |> body()
      send_json(:post, "/v1/codes/#{id}/codevalues", %{"name" => "North"})

      assert call(:delete, "/api/v1/codes/#{id}", auth: admin()).status == 200

      assert %{rows: [[0]]} =
               ECBPlatform.TenantRepo.query!(
                 "SELECT count(*) FROM m_code_value WHERE code_id = $1",
                 [id]
               )
    end

    test "a code can be worked on by name" do
      send_json(:post, "/v1/codes", %{"name" => "Region"})

      assert send_json(:post, "/v1/codes/name/Region/codevalues", %{"name" => "North"}).status ==
               200

      assert [%{"name" => "North"}] =
               call(:get, "/api/v1/codes/name/Region/codevalues", auth: admin()) |> body()
    end

    test "a user without UPDATE_CODEVALUE cannot change a value" do
      %{"subResourceId" => value_id, "resourceId" => id} =
        send_json(:post, "/v1/codes", %{"name" => "Region"})
        |> body()
        |> then(&send_json(:post, "/v1/codes/#{&1["resourceId"]}/codevalues", %{"name" => "N"}))
        |> body()

      user = make_user("code-reader", ["READ_CODEVALUE"])

      assert send_json(:put, "/v1/codes/#{id}/codevalues/#{value_id}", %{"name" => "X"}, user).status ==
               403
    end
  end

  describe "working days" do
    test "a rule that cannot be read is refused with the reason, and nothing changes" do
      before_rule =
        call(:get, "/api/v1/workingdays", auth: admin()) |> body() |> Map.fetch!("recurrence")

      for bad <- ["not a rule", "FREQ=NEVER", "FREQ=WEEKLY;BYDAY=XX"] do
        conn = send_json(:put, "/v1/workingdays", %{"recurrence" => bad})
        assert conn.status == 403

        assert body(conn)["userMessageGlobalisationCode"] ==
                 "error.msg.recurring.rule.parsing.error"
      end

      assert call(:get, "/api/v1/workingdays", auth: admin())
             |> body()
             |> Map.fetch!("recurrence") == before_rule
    end

    test "a rule without a frequency is refused as not valid" do
      conn = send_json(:put, "/v1/workingdays", %{"recurrence" => "INTERVAL=1;BYDAY=MO"})
      assert conn.status == 403
      assert body(conn)["userMessageGlobalisationCode"] == "error.msg.invalid.recurring.rule"
    end
  end

  describe "holidays" do
    @dates %{"dateFormat" => "dd MMMM yyyy", "locale" => "en"}

    defp holiday(extra) do
      send_json(
        :post,
        "/v1/holidays",
        Map.merge(
          %{
            "name" => "Christmas",
            "fromDate" => "25 December 2026",
            "toDate" => "26 December 2026",
            "reschedulingType" => 1,
            "offices" => [%{"officeId" => 1}]
          },
          Map.merge(@dates, extra)
        )
      )
    end

    test "a name in use is refused with its own message" do
      assert holiday(%{}).status == 200
      conn = holiday(%{})
      assert conn.status == 403
      assert body(conn)["userMessageGlobalisationCode"] == "error.msg.holiday.duplicate.name"
    end

    test "repayments cannot be moved to a day that is not a working day" do
      # Saturday and Sunday are not working days
      send_json(:put, "/v1/workingdays", %{
        "recurrence" => "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR"
      })

      conn = holiday(%{"reschedulingType" => 2, "repaymentsRescheduledTo" => "27 December 2026"})
      assert conn.status == 403

      assert body(conn)["errors"] |> hd() |> Map.fetch!("userMessageGlobalisationCode") ==
               "error.msg.holiday.repayments.rescheduled.date.should.not.fall.on.non.working.day"

      assert holiday(%{"reschedulingType" => 2, "repaymentsRescheduledTo" => "28 December 2026"}).status ==
               200
    end

    test "an active holiday keeps its dates but its description can change" do
      %{"resourceId" => id} = holiday(%{}) |> body()
      assert send_json(:post, "/v1/holidays/#{id}?command=activate", nil).status == 200

      locked =
        send_json(
          :put,
          "/v1/holidays/#{id}",
          Map.merge(%{"toDate" => "30 December 2026"}, @dates)
        )

      assert locked.status == 400

      assert send_json(:put, "/v1/holidays/#{id}", %{"description" => "Public holiday"}).status ==
               200
    end

    test "deleting keeps the row, marked deleted, and it is still listed" do
      %{"resourceId" => id} = holiday(%{}) |> body()
      assert call(:delete, "/api/v1/holidays/#{id}", auth: admin()).status == 200

      [one] = call(:get, "/api/v1/holidays?officeId=1", auth: admin()) |> body()
      assert one["status"]["value"] == "Deleted"
    end

    test "a user without UPDATE_HOLIDAY cannot activate" do
      %{"resourceId" => id} = holiday(%{}) |> body()
      reader = make_user("holiday-reader", ["READ_HOLIDAY"])
      assert send_json(:post, "/v1/holidays/#{id}?command=activate", nil, reader).status == 403
    end
  end
end
