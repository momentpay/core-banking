defmodule ECBApiFineract.SavingsProductsTest do
  @moduledoc """
  Savings products beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions,
  what the product-to-ledger mappings protect, and what deleting a product leaves behind.
  """
  use ECBApiFineract.ApiCase

  import Ecto.Query

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp account(code, type) do
    conn =
      send_json(:post, "/v1/glaccounts", %{
        "name" => "Acc " <> code,
        "glCode" => code,
        "manualEntriesAllowed" => true,
        "type" => type,
        "usage" => 1
      })

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

  defp cash_accounts do
    %{
      "accountingRule" => 2,
      "savingsReferenceAccountId" => account("A1", 1),
      "overdraftPortfolioControlId" => account("A2", 1),
      "savingsControlAccountId" => account("L1", 2),
      "transfersInSuspenseAccountId" => account("L2", 2),
      "incomeFromFeeAccountId" => account("I1", 4),
      "incomeFromPenaltyAccountId" => account("I2", 4),
      "incomeFromInterestId" => account("I3", 4),
      "interestOnSavingsAccountId" => account("X1", 5),
      "writeOffAccountId" => account("X2", 5)
    }
  end

  describe "permissions" do
    test "reading needs READ_SAVINGSPRODUCT and each write its own permission" do
      request = %{
        "name" => "P",
        "shortName" => "PPPP",
        "currencyCode" => "USD",
        "digitsAfterDecimal" => 2,
        "nominalAnnualInterestRate" => 1,
        "interestCompoundingPeriodType" => 1,
        "interestPostingPeriodType" => 4,
        "interestCalculationType" => 1,
        "interestCalculationDaysInYearType" => 365,
        "accountingRule" => 1,
        "locale" => "en"
      }

      assert send_json(:get, "/v1/savingsproducts", nil, make_user("sp-none", [])).status == 403

      assert send_json(
               :get,
               "/v1/savingsproducts",
               nil,
               make_user("sp-read", ["READ_SAVINGSPRODUCT"])
             ).status ==
               200

      assert send_json(
               :post,
               "/v1/savingsproducts",
               request,
               make_user("sp-no-create", ["READ_SAVINGSPRODUCT"])
             ).status ==
               403

      created =
        send_json(
          :post,
          "/v1/savingsproducts",
          request,
          make_user("sp-create", ["CREATE_SAVINGSPRODUCT"])
        )

      assert created.status == 200
      id = body(created)["resourceId"]

      change = %{"description" => "x", "locale" => "en"}

      assert send_json(
               :put,
               "/v1/savingsproducts/#{id}",
               change,
               make_user("sp-no-update", ["CREATE_SAVINGSPRODUCT"])
             ).status == 403

      assert send_json(
               :put,
               "/v1/savingsproducts/#{id}",
               change,
               make_user("sp-update", ["UPDATE_SAVINGSPRODUCT"])
             ).status == 200

      assert send_json(
               :delete,
               "/v1/savingsproducts/#{id}",
               nil,
               make_user("sp-no-delete", ["UPDATE_SAVINGSPRODUCT"])
             ).status == 403

      assert send_json(
               :delete,
               "/v1/savingsproducts/#{id}",
               nil,
               make_user("sp-delete", ["DELETE_SAVINGSPRODUCT"])
             ).status == 200
    end
  end

  describe "the ledger" do
    test "an account a product is mapped to cannot be deleted" do
      accounts = cash_accounts()
      product(accounts)

      refused = send_json(:delete, "/v1/glaccounts/#{accounts["savingsControlAccountId"]}")
      assert refused.status == 403
    end

    test "a product keeps its charges and mappings in separate tables" do
      accounts = cash_accounts()
      id = product(accounts)

      assert TenantRepo.aggregate(
               from(m in "acc_product_mapping", where: m.product_id == ^id),
               :count
             ) == 9
    end

    test "deleting a product leaves its mappings behind, as Fineract does" do
      id = product(cash_accounts())
      assert send_json(:delete, "/v1/savingsproducts/#{id}").status == 200

      assert send_json(:get, "/v1/savingsproducts/#{id}").status == 404

      assert TenantRepo.aggregate(
               from(m in "acc_product_mapping", where: m.product_id == ^id),
               :count
             ) == 9
    end
  end

  describe "commands" do
    test "every write is recorded as a command" do
      id = product()

      send_json(:put, "/v1/savingsproducts/#{id}", %{"description" => "changed", "locale" => "en"})

      send_json(:delete, "/v1/savingsproducts/#{id}")

      actions =
        TenantRepo.all(
          from(c in "m_portfolio_command_source",
            where: c.entity_name == "SAVINGSPRODUCT",
            order_by: c.id,
            select: c.action_name
          )
        )

      assert actions == ["CREATE", "UPDATE", "DELETE"]
    end
  end

  describe "money figures" do
    test "the opening balance is rounded to the product's decimals" do
      id = product(%{"minRequiredOpeningBalance" => 100.555})
      shown = body(send_json(:get, "/v1/savingsproducts/#{id}"))["minRequiredOpeningBalance"]
      assert shown == 100.56
    end
  end
end
