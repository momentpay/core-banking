defmodule ECBApiFineract.SavingsAccountChargesTest do
  @moduledoc """
  The charges of a savings account beyond the responses recorded from Fineract (those are in `ScenariosTest`):
  permissions, what is paid and waived, how fees reach the totals of the account, and what is refused because it is
  not built yet.
  """
  use ECBApiFineract.ApiCase

  @dates %{"dateFormat" => "yyyy-MM-dd", "locale" => "en"}

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp today, do: Date.to_iso8601(Date.utc_today())

  defp ok(conn) do
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp charge(time, amount, extra \\ %{}) do
    request =
      Map.merge(
        %{
          "name" => "Fee #{System.unique_integer([:positive])}",
          "currencyCode" => "USD",
          "chargeAppliesTo" => 2,
          "chargeTimeType" => time,
          "chargeCalculationType" => 1,
          "amount" => amount,
          "active" => true,
          "penalty" => false,
          "locale" => "en"
        },
        extra
      )

    send_json(:post, "/v1/charges", request) |> ok() |> Map.fetch!("resourceId")
  end

  # an active account holding `balance`
  defp account(balance) do
    client =
      send_json(
        :post,
        "/v1/clients",
        Map.merge(
          %{
            "officeId" => 1,
            "legalFormId" => 1,
            "firstname" => "Ann",
            "lastname" => "Lee",
            "active" => true,
            "activationDate" => "2020-01-01"
          },
          @dates
        )
      )
      |> ok()
      |> Map.fetch!("resourceId")

    send_json(:post, "/v1/paymenttypes", %{
      "name" => "Cash",
      "description" => "c",
      "isCashPayment" => true,
      "position" => 1
    })

    product =
      send_json(:post, "/v1/savingsproducts", %{
        "name" => "Basic",
        "shortName" => "BSIC",
        "currencyCode" => "USD",
        "digitsAfterDecimal" => 2,
        "nominalAnnualInterestRate" => 0,
        "interestCompoundingPeriodType" => 1,
        "interestPostingPeriodType" => 4,
        "interestCalculationType" => 1,
        "interestCalculationDaysInYearType" => 365,
        "accountingRule" => 1,
        "locale" => "en"
      })
      |> ok()
      |> Map.fetch!("resourceId")

    id =
      send_json(
        :post,
        "/v1/savingsaccounts",
        Map.merge(
          %{"clientId" => client, "productId" => product, "submittedOnDate" => today()},
          @dates
        )
      )
      |> ok()
      |> Map.fetch!("resourceId")

    command(id, "approve", %{"approvedOnDate" => today()}) |> ok()
    command(id, "activate", %{"activatedOnDate" => today()}) |> ok()

    if balance > 0, do: deposit(id, balance)
    id
  end

  defp command(id, name, extra),
    do: send_json(:post, "/v1/savingsaccounts/#{id}?command=#{name}", Map.merge(@dates, extra))

  defp deposit(id, amount),
    do:
      send_json(
        :post,
        "/v1/savingsaccounts/#{id}/transactions?command=deposit",
        Map.merge(
          %{"transactionDate" => today(), "transactionAmount" => amount, "paymentTypeId" => 1},
          @dates
        )
      )
      |> ok()

  defp add(id, charge_id, amount, extra \\ %{}),
    do:
      send_json(
        :post,
        "/v1/savingsaccounts/#{id}/charges",
        Map.merge(%{"chargeId" => charge_id, "amount" => amount}, Map.merge(@dates, extra))
      )

  defp added(conn), do: conn |> ok() |> Map.fetch!("resourceId")

  defp summary(id),
    do: send_json(:get, "/v1/savingsaccounts/#{id}") |> ok() |> Map.fetch!("summary")

  defp pay(id, charge_id, amount) do
    send_json(
      :post,
      "/v1/savingsaccounts/#{id}/charges/#{charge_id}?command=paycharge",
      Map.merge(%{"amount" => amount, "dueDate" => today()}, @dates)
    )
  end

  test "each action needs its own permission" do
    id = account(100)
    fee = charge(2, 5)

    assert send_json(:get, "/v1/savingsaccounts/#{id}/charges", nil, make_user("c-none", [])).status ==
             403

    assert send_json(
             :get,
             "/v1/savingsaccounts/#{id}/charges",
             nil,
             make_user("c-read", ["READ_SAVINGSACCOUNTCHARGE"])
           ).status == 200

    request = Map.merge(%{"chargeId" => fee, "amount" => 5, "dueDate" => today()}, @dates)

    assert send_json(
             :post,
             "/v1/savingsaccounts/#{id}/charges",
             request,
             make_user("c-no-create", ["READ_SAVINGSACCOUNTCHARGE"])
           ).status == 403

    assert send_json(
             :post,
             "/v1/savingsaccounts/#{id}/charges",
             request,
             make_user("c-create", ["CREATE_SAVINGSACCOUNTCHARGE"])
           ).status == 200
  end

  test "a charge paid takes its amount out of the account and counts as a fee, or as a penalty" do
    id = account(100)
    fee_id = id |> add(charge(2, 10), 10, %{"dueDate" => today()}) |> added()

    penalty_id =
      id |> add(charge(2, 4, %{"penalty" => true}), 4, %{"dueDate" => today()}) |> added()

    assert pay(id, fee_id, 6).status == 200
    assert pay(id, fee_id, 6).status == 400
    assert pay(id, fee_id, 4).status == 200
    assert pay(id, penalty_id, 4).status == 200

    summary = summary(id)
    assert summary["accountBalance"] == 86
    assert summary["totalFeeCharge"] == 10
    assert summary["totalPenaltyCharge"] == 4

    paid = send_json(:get, "/v1/savingsaccounts/#{id}/charges/#{fee_id}") |> ok()
    assert paid["amountPaid"] == 10
    assert paid["amountOutstanding"] == 0
  end

  test "a payment larger than the balance is refused" do
    id = account(3)
    fee_id = id |> add(charge(2, 10), 10, %{"dueDate" => today()}) |> added()

    conn = pay(id, fee_id, 10)
    assert conn.status == 403

    assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
             "error.msg.savingsaccount.transaction.insufficient.account.balance"
  end

  test "a withdrawal pays the withdrawal fee, and undoing the withdrawal takes the fee back" do
    id = account(100)
    charge_id = id |> add(charge(5, 2), 2) |> added()

    withdrawal =
      send_json(
        :post,
        "/v1/savingsaccounts/#{id}/transactions?command=withdrawal",
        Map.merge(
          %{"transactionDate" => today(), "transactionAmount" => 30, "paymentTypeId" => 1},
          @dates
        )
      )
      |> ok()

    summary = summary(id)
    assert summary["accountBalance"] == 68
    assert summary["totalWithdrawalFees"] == 2

    assert send_json(
             :post,
             "/v1/savingsaccounts/#{id}/transactions/#{withdrawal["resourceId"]}?command=undo",
             %{}
           ).status == 200

    assert summary(id)["accountBalance"] == 100

    assert send_json(:get, "/v1/savingsaccounts/#{id}/charges/#{charge_id}")
           |> ok()
           |> Map.fetch!("amountPaid") == 0
  end

  test "a waived charge takes nothing from the account, and a withdrawal fee cannot be waived" do
    id = account(50)
    fee_id = id |> add(charge(2, 10), 10, %{"dueDate" => today()}) |> added()
    withdrawal_fee_id = id |> add(charge(5, 1), 1) |> added()

    waive = fn charge_id ->
      send_json(:post, "/v1/savingsaccounts/#{id}/charges/#{charge_id}?command=waive", %{})
    end

    assert waive.(fee_id).status == 200
    assert waive.(fee_id).status == 400
    assert waive.(withdrawal_fee_id).status == 400
    assert summary(id)["accountBalance"] == 50
  end

  test "a charge of an active account cannot be deleted" do
    id = account(0)
    charge_id = id |> add(charge(2, 10), 10, %{"dueDate" => today()}) |> added()
    assert send_json(:delete, "/v1/savingsaccounts/#{id}/charges/#{charge_id}").status == 400
  end

  test "an annual fee falls due on its day each year, and only one is allowed" do
    id = account(0)
    annual = charge(6, 12, %{"feeOnMonthDay" => "15 June", "monthDayFormat" => "dd MMMM"})
    day = %{"feeOnMonthDay" => "15 June", "monthDayFormat" => "dd MMMM"}

    assert add(id, annual, 12, day).status == 200
    assert add(id, annual, 12, day).status == 400

    [due] =
      send_json(:get, "/v1/savingsaccounts/#{id}/charges") |> ok() |> Enum.map(& &1["dueDate"])

    assert [_year, 6, 15] = due
  end

  test "a charge that belongs to a payment type is refused as not supported yet" do
    id = account(0)
    typed = charge(5, 2, %{"enablePaymentType" => true, "paymentTypeId" => 1})

    conn = add(id, typed, 2)
    assert conn.status == 403

    assert hd(body(conn)["errors"])["userMessageGlobalisationCode"] ==
             "error.msg.savingsaccount.feature.not.supported.yet"
  end
end
