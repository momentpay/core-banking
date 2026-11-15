defmodule ECBApiFineract.ProvisioningTest do
  @moduledoc """
  Loan provisioning beyond the responses recorded from Fineract (those are in `ScenariosTest`):
  permissions, and a category that a criteria uses.
  """
  use ECBApiFineract.ApiCase

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  describe "categories" do
    test "can be listed by any signed-in user, but changing them needs a permission" do
      nobody = make_user("prov-nobody", ["READ_OFFICE"])
      assert send_json(:get, "/v1/provisioningcategory", nil, nobody).status == 200
      assert send_json(:get, "/v1/provisioningcriteria", nil, nobody).status == 200
      assert send_json(:get, "/v1/provisioningentries", nil, nobody).status == 200

      assert send_json(:post, "/v1/provisioningcategory", %{"categoryname" => "X"}, nobody).status ==
               403

      creator = make_user("prov-creator", ["CREATE_PROVISIONCATEGORY"])

      assert send_json(:post, "/v1/provisioningcategory", %{"categoryname" => "X"}, creator).status ==
               200

      assert send_json(:put, "/v1/provisioningcategory/5", %{"categoryname" => "Y"}, creator).status ==
               403

      assert send_json(:delete, "/v1/provisioningcategory/5", nil, creator).status == 403
    end

    test "one that a criteria uses cannot be deleted" do
      {:ok, %{rows: [[liability]]}} =
        TenantRepo.query(
          "INSERT INTO acc_gl_account (name, gl_code, disabled, manual_journal_entries_allowed, classification_enum, account_usage) VALUES ('L', '2', false, true, 2, 1) RETURNING id"
        )

      TenantRepo.query!(
        "INSERT INTO m_provisioning_criteria (id, criteria_name) VALUES (1, 'Standard rules')"
      )

      TenantRepo.query!(
        "INSERT INTO m_provisioning_criteria_definition (id, criteria_id, category_id, min_age, max_age, provision_percentage, liability_account, expense_account) VALUES (1, 1, 2, 0, 30, 1, $1, $1)",
        [liability]
      )

      conn = send_json(:delete, "/v1/provisioningcategory/2")
      assert conn.status == 403

      assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
               "error.msg.provisioningcategory.cannot.be.deleted.it.is.already.used.in.loanproduct"

      [criteria] = body(send_json(:get, "/v1/provisioningcriteria"))
      assert criteria["criteriaName"] == "Standard rules"

      shown = body(send_json(:get, "/v1/provisioningcriteria/1"))
      assert [%{"categoryName" => "SUB-STANDARD", "maxAge" => 30}] = shown["definitions"]

      TenantRepo.query!("DELETE FROM m_provisioning_criteria_definition")
      TenantRepo.query!("DELETE FROM m_provisioning_criteria")
      assert send_json(:delete, "/v1/provisioningcategory/2").status == 200
    end
  end
end
