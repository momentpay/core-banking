defmodule ECBApiFineract.LoanProductsTest do
  @moduledoc """
  Loan products beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions, what a
  product asks for that E-CoreBank does not support yet, what the ledger mappings protect, and the figures
  worked out from the request.
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

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "Basic",
        "shortName" => "BSIC",
        "currencyCode" => "USD",
        "digitsAfterDecimal" => 2,
        "inMultiplesOf" => 0,
        "principal" => 10_000,
        "numberOfRepayments" => 12,
        "repaymentEvery" => 1,
        "repaymentFrequencyType" => 2,
        "interestRatePerPeriod" => 1.5,
        "interestRateFrequencyType" => 2,
        "amortizationType" => 1,
        "interestType" => 0,
        "interestCalculationPeriodType" => 1,
        "transactionProcessingStrategyCode" => "mifos-standard-strategy",
        "daysInYearType" => 365,
        "daysInMonthType" => 30,
        "isInterestRecalculationEnabled" => false,
        "accountingRule" => 1,
        "locale" => "en"
      },
      extra
    )
  end

  defp product(extra \\ %{}) do
    conn = send_json(:post, "/v1/loanproducts", request(extra))
    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  defp cash_accounts do
    %{
      "accountingRule" => 2,
      "fundSourceAccountId" => account("A1", 1),
      "loanPortfolioAccountId" => account("A2", 1),
      "transfersInSuspenseAccountId" => account("A3", 1),
      "overpaymentLiabilityAccountId" => account("L1", 2),
      "interestOnLoanAccountId" => account("I1", 4),
      "incomeFromFeeAccountId" => account("I2", 4),
      "incomeFromPenaltyAccountId" => account("I3", 4),
      "incomeFromRecoveryAccountId" => account("I4", 4),
      "writeOffAccountId" => account("X1", 5)
    }
  end

  describe "permissions" do
    test "reading needs READ_LOANPRODUCT and creating CREATE_LOANPRODUCT" do
      assert send_json(:get, "/v1/loanproducts", nil, make_user("lp-none", [])).status == 403

      assert send_json(
               :get,
               "/v1/loanproducts",
               nil,
               make_user("lp-read", ["READ_LOANPRODUCT"])
             ).status == 200

      assert send_json(
               :post,
               "/v1/loanproducts",
               request(),
               make_user("lp-no-create", ["READ_LOANPRODUCT"])
             ).status == 403

      assert send_json(
               :post,
               "/v1/loanproducts",
               request(),
               make_user("lp-create", ["CREATE_LOANPRODUCT"])
             ).status == 200
    end

    test "a change is checked for UPDATE_LOANPRODUCT before anything else" do
      id = product()
      change = %{"description" => "x", "locale" => "en"}

      assert send_json(
               :put,
               "/v1/loanproducts/#{id}",
               change,
               make_user("lp-no-update", ["CREATE_LOANPRODUCT"])
             ).status == 403
    end
  end

  describe "what is not supported yet" do
    test "a feature beyond the core term loan is refused, not ignored" do
      refused = fn extra ->
        conn = send_json(:post, "/v1/loanproducts", request(extra))
        {conn.status, body(conn)}
      end

      for extra <- [
            %{"isInterestRecalculationEnabled" => true},
            %{"useBorrowerCycle" => true},
            %{"holdGuaranteeFunds" => true},
            %{"isLinkedToFloatingInterestRates" => true},
            %{"enableDownPayment" => true},
            %{"allowVariableInstallments" => true}
          ] do
        {status, response} = refused.(extra)
        assert status == 403, inspect(extra)

        assert [
                 %{
                   "userMessageGlobalisationCode" =>
                     "error.msg.loanproduct.feature.not.supported.yet"
                 }
               ] =
                 response["errors"]
      end

      assert TenantRepo.aggregate(from(lp in "m_product_loan"), :count) == 0
    end

    test "changing a product is refused with a clear message" do
      id = product()

      conn =
        send_json(:put, "/v1/loanproducts/#{id}", %{"description" => "changed", "locale" => "en"})

      assert conn.status == 403

      assert [
               %{
                 "userMessageGlobalisationCode" =>
                   "error.msg.loanproduct.feature.not.supported.yet"
               }
             ] =
               body(conn)["errors"]
    end

    test "changing a product that does not exist is a plain not found" do
      conn = send_json(:put, "/v1/loanproducts/99", %{"description" => "x", "locale" => "en"})
      assert conn.status == 404
    end

    test "a loan product cannot be deleted" do
      id = product()
      assert send_json(:delete, "/v1/loanproducts/#{id}").status == 405
      assert send_json(:get, "/v1/loanproducts/#{id}").status == 200
    end
  end

  describe "the ledger" do
    test "an account a product is mapped to cannot be deleted" do
      accounts = cash_accounts()
      product(Map.put(accounts, "shortName", "CASH"))

      refused = send_json(:delete, "/v1/glaccounts/#{accounts["loanPortfolioAccountId"]}")
      assert refused.status == 403
    end

    test "a cash product maps every account it names, under the product's id" do
      id = product(Map.put(cash_accounts(), "shortName", "CASH"))

      assert TenantRepo.aggregate(
               from(m in "acc_product_mapping",
                 where: m.product_id == ^id and m.product_type == 1
               ),
               :count
             ) == 9
    end

    test "the accounts show on the product by what they are for" do
      accounts = cash_accounts()
      id = product(Map.put(accounts, "shortName", "CASH"))

      shown = body(send_json(:get, "/v1/loanproducts/#{id}"))["accountingMappings"]
      assert shown["loanPortfolioAccount"]["id"] == accounts["loanPortfolioAccountId"]
      assert shown["interestOnLoanAccount"]["id"] == accounts["interestOnLoanAccountId"]
      assert shown["writeOffAccount"]["id"] == accounts["writeOffAccountId"]
    end
  end

  describe "commands" do
    test "a create is recorded as a command" do
      product()

      actions =
        TenantRepo.all(
          from(c in "m_portfolio_command_source",
            where: c.entity_name == "LOANPRODUCT",
            order_by: c.id,
            select: c.action_name
          )
        )

      assert actions == ["CREATE"]
    end
  end

  describe "figures worked out from the request" do
    test "the yearly rate follows the rate per period and how often it is quoted" do
      rate = fn extra ->
        id = product(Map.merge(%{"name" => "Rate " <> extra["shortName"]}, extra))
        body(send_json(:get, "/v1/loanproducts/#{id}"))["annualInterestRate"]
      end

      assert rate.(%{"shortName" => "MNTH"}) == 18.0
      assert rate.(%{"shortName" => "YEAR", "interestRateFrequencyType" => 3}) == 1.5

      assert rate.(%{
               "shortName" => "WEEK",
               "interestRateFrequencyType" => 1,
               "repaymentFrequencyType" => 1
             }) == 78.0
    end

    test "a close date before the business date makes the product inactive" do
      id =
        product(%{
          "closeDate" => "01 January 2020",
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })

      shown = body(send_json(:get, "/v1/loanproducts/#{id}"))
      assert shown["status"] == "loanProduct.inActive"
      assert shown["closeDate"] == [2020, 1, 1]
      refute Map.has_key?(shown, "startDate")
    end
  end
end
