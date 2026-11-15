defmodule ECBApiFineract.ChargesTest do
  @moduledoc """
  Charges beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions, what
  deleting does, charges hidden by their currency, and a charge that a product uses.
  """
  use ECBApiFineract.ApiCase

  import Ecto.Query

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp charge(extra \\ %{}) do
    request =
      Map.merge(
        %{
          "name" => "Fee",
          "currencyCode" => "USD",
          "chargeAppliesTo" => 1,
          "chargeTimeType" => 1,
          "chargeCalculationType" => 1,
          "chargePaymentMode" => 0,
          "amount" => 10,
          "locale" => "en"
        },
        extra
      )

    conn = send_json(:post, "/v1/charges", request)
    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  describe "deleting" do
    test "flags the charge and frees its name for another" do
      id = charge()

      assert send_json(:delete, "/v1/charges/#{id}").status == 200
      assert send_json(:get, "/v1/charges/#{id}").status == 404
      assert body(send_json(:get, "/v1/charges")) == []

      expected = "#{id}_Fee"

      assert [%{name: ^expected, is_deleted: true}] =
               TenantRepo.all(
                 from(c in "m_charge", select: %{name: c.name, is_deleted: c.is_deleted})
               )

      assert charge() != id
    end

    test "is refused while a loan product uses the charge" do
      id = charge(%{"active" => true})

      product =
        send_json(:post, "/v1/loanproducts", %{
          "name" => "Basic",
          "shortName" => "BSIC",
          "currencyCode" => "USD",
          "digitsAfterDecimal" => 2,
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
          "charges" => [%{"id" => id}],
          "locale" => "en"
        })

      assert product.status == 200, product.resp_body

      refused = send_json(:delete, "/v1/charges/#{id}")
      assert refused.status == 403

      assert hd(body(refused)["errors"])["userMessageGlobalisationCode"] ==
               "error.msg.charge.cannot.be.deleted.it.is.already.used.in.loan"

      TenantRepo.query!("DELETE FROM m_product_loan_charge")
      assert send_json(:delete, "/v1/charges/#{id}").status == 200
    end
  end

  describe "currency" do
    test "a charge in a currency the organisation has not selected is saved but not shown" do
      id = charge(%{"name" => "Euro fee", "currencyCode" => "EUR"})

      assert send_json(:get, "/v1/charges/#{id}").status == 404
      assert body(send_json(:get, "/v1/charges")) == []
      assert TenantRepo.aggregate("m_charge", :count) == 1
    end
  end

  describe "the free-withdrawal settings" do
    test "are not stored, as Fineract does not store them" do
      id =
        charge(%{
          "name" => "Withdrawal",
          "chargeAppliesTo" => 2,
          "chargeTimeType" => 5,
          "chargePaymentMode" => nil,
          "enableFreeWithdrawalCharge" => true,
          "freeWithdrawalFrequency" => 3
        })

      shown = body(send_json(:get, "/v1/charges/#{id}"))
      assert shown["freeWithdrawal"] == false
      assert shown["freeWithdrawalChargeFrequency"] == 0
    end
  end

  describe "a savings charge" do
    test "falls due on the day and month it names" do
      id =
        charge(%{
          "name" => "Monthly",
          "chargeAppliesTo" => 2,
          "chargeTimeType" => 7,
          "chargePaymentMode" => nil,
          "feeOnMonthDay" => "29 February",
          "monthDayFormat" => "dd MMMM",
          "feeInterval" => 3
        })

      shown = body(send_json(:get, "/v1/charges/#{id}"))
      assert shown["feeOnMonthDay"] == "--02-29"
      assert shown["feeInterval"] == 3
    end
  end

  describe "permissions" do
    test "reading needs READ_CHARGE and each write its own permission" do
      reader = make_user("charge-reader", ["READ_CHARGE"])
      assert send_json(:get, "/v1/charges", nil, reader).status == 200
      assert send_json(:get, "/v1/charges/template", nil, reader).status == 200

      request = %{
        "name" => "X",
        "currencyCode" => "USD",
        "chargeAppliesTo" => 3,
        "chargeTimeType" => 2,
        "chargeCalculationType" => 1,
        "amount" => 1,
        "locale" => "en"
      }

      assert send_json(:post, "/v1/charges", request, reader).status == 403

      creator = make_user("charge-creator", ["CREATE_CHARGE"])
      assert send_json(:post, "/v1/charges", request, creator).status == 200
      assert send_json(:put, "/v1/charges/1", %{"name" => "Y"}, creator).status == 403
      assert send_json(:delete, "/v1/charges/1", nil, creator).status == 403

      nobody = make_user("charge-nobody", ["READ_OFFICE"])
      assert send_json(:get, "/v1/charges", nil, nobody).status == 403
    end
  end
end
