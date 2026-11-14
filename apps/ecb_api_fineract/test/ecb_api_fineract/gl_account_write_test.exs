defmodule ECBApiFineract.GLAccountWriteTest do
  @moduledoc """
  The chart of accounts beyond the responses recorded from Fineract (those are in `ScenariosTest`): the
  rules that need postings or product mappings to exist, duplicate codes, and moving a branch of the chart.
  """
  use ECBApiFineract.ApiCase

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp account(code, extra \\ %{}) do
    send_json(
      :post,
      "/v1/glaccounts",
      Map.merge(
        %{
          "name" => "Account #{code}",
          "glCode" => code,
          "manualEntriesAllowed" => true,
          "type" => 1,
          "usage" => 1
        },
        extra
      )
    )
  end

  defp id_of(conn), do: body(conn)["resourceId"]

  defp post_entry(account_id) do
    TenantRepo.query!(
      """
      INSERT INTO acc_gl_journal_entry (account_id, office_id, currency_code, transaction_id, entry_date, type_enum, amount,
        created_by, last_modified_by, created_on_utc, last_modified_on_utc, submitted_on_date)
      VALUES ($1, 1, 'USD', 'T1', CURRENT_DATE, 1, 10, 1, 1, now(), now(), CURRENT_DATE)
      """,
      [account_id]
    )
  end

  test "a GL code already in use is refused with its own message" do
    account("1000")
    conn = account("1000")

    assert conn.status == 403
    assert body(conn)["userMessageGlobalisationCode"] == "error.msg.glaccount.glcode.duplicate"
  end

  test "moving an account moves the accounts beneath it (a root account's path is \".\", so its children start at their own ids)" do
    top = account("1", %{"usage" => 2}) |> id_of()
    other = account("2", %{"usage" => 2}) |> id_of()
    mid = account("11", %{"usage" => 2, "parentId" => top}) |> id_of()
    leaf = account("111", %{"parentId" => mid}) |> id_of()

    assert body(send_json(:get, "/v1/glaccounts/#{leaf}"))["nameDecorated"] ==
             "........Account 111"

    assert send_json(:put, "/v1/glaccounts/#{mid}", %{"parentId" => other}).status == 200

    assert TenantRepo.query!("SELECT hierarchy FROM acc_gl_account WHERE id = $1", [leaf]).rows ==
             [[".#{mid}.#{leaf}."]]
  end

  test "an account with postings cannot be deleted or turned into a header" do
    id = account("1000") |> id_of()
    post_entry(id)

    deleted = send_json(:delete, "/v1/glaccounts/#{id}")
    assert deleted.status == 403

    assert hd(body(deleted)["errors"])["userMessageGlobalisationCode"] ==
             "error.msg.glaccount.glcode.invalid.delete.transactions.logged"

    header = send_json(:put, "/v1/glaccounts/#{id}", %{"usage" => 2, "name" => "Renamed"})
    assert header.status == 403

    assert hd(body(header)["errors"])["userMessageGlobalisationCode"] ==
             "error.msg.glaccount.glcode.invalid.update.transactions.logged"
  end

  test "an account mapped to a product can be neither disabled nor deleted" do
    id = account("1000") |> id_of()

    TenantRepo.query!(
      "INSERT INTO acc_product_mapping (gl_account_id, product_id, product_type, financial_account_type) VALUES ($1, 1, 1, 1)",
      [id]
    )

    disabled = send_json(:put, "/v1/glaccounts/#{id}", %{"disabled" => true})
    assert disabled.status == 403

    assert hd(body(disabled)["errors"])["userMessageGlobalisationCode"] ==
             "error.msg.glaccount.attached.to.product"

    deleted = send_json(:delete, "/v1/glaccounts/#{id}")

    assert hd(body(deleted)["errors"])["userMessageGlobalisationCode"] ==
             "error.msg.glaccount.glcode.invalid.delete.product.mapping"
  end

  test "reading needs READ_GLACCOUNT and writing the matching permission" do
    reader = make_user("gl-reader", ["READ_GLACCOUNT"])
    assert send_json(:get, "/v1/glaccounts", nil, reader).status == 200
    assert send_json(:post, "/v1/glaccounts", %{"name" => "x"}, reader).status == 403

    nobody = make_user("gl-nobody", ["READ_OFFICE"])
    assert send_json(:get, "/v1/glaccounts", nil, nobody).status == 403
  end

  test "the list can be searched by part of the name or code" do
    account("1000")
    account("2000")

    names = fn conn -> body(conn) |> Enum.map(& &1["glCode"]) end
    assert names.(send_json(:get, "/v1/glaccounts?searchParam=200")) == ["2000"]
    assert names.(send_json(:get, "/v1/glaccounts?searchParam=Account")) == ["1000", "2000"]
  end
end
