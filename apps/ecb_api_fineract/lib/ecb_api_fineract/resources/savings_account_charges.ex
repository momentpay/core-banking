defmodule ECBApiFineract.Resources.SavingsAccountCharges do
  @moduledoc """
  `/savingsaccounts/{id}/charges`: the charges of a savings account, one of them, the template for adding one, and
  adding, changing, deleting, paying, waiving and inactivating them. Answers as Fineract's
  `SavingsAccountChargesApiResource` does.
  """
  import Ecto.Query

  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Charges, Read, SavingsAccounts, Write}
  alias ECBCatalog.Charges, as: CatalogCharges
  alias ECBCatalog.Charges.Enums
  alias ECBDeposits.Savings
  alias ECBDeposits.Savings.Charges, as: AccountCharges
  alias ECBPlatform.Errors.UnrecognizedQueryParameter
  alias ECBPlatform.TenantRepo

  @resource "SAVINGSACCOUNTCHARGE"
  @commands %{"paycharge" => "PAY", "waive" => "WAIVE", "inactivate" => "INACTIVATE"}

  # --- reads ----------------------------------------------------------------------------------

  @doc "`GET /savingsaccounts/:id/charges`"
  def index(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      status = conn.query_params["chargeStatus"] || "all"
      Read.respond(conn, @resource, fn -> list(id, status) end)
    end)
  end

  defp list(id, status) do
    if String.downcase(status) in ["all", "active", "inactive"] do
      account = Savings.fetch!(id)
      Enum.map(AccountCharges.list(id, status), &json(&1, account))
    else
      {:error,
       %UnrecognizedQueryParameter{
         name: "status",
         value: status,
         allowed: ["all", "active", "inactive"]
       }}
    end
  end

  @doc "`GET /savingsaccounts/:id/charges/template`"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        account = Savings.fetch!(id)

        %{
          "percentage" => 0,
          "amountPercentageAppliedTo" => 0,
          "amount" => 0,
          "amountPaid" => 0,
          "amountWaived" => 0,
          "amountWrittenOff" => 0,
          "amountOutstanding" => 0,
          "amountOrPercentage" => 0,
          "penalty" => false,
          "chargeOptions" =>
            CatalogCharges.applicable_to_savings(false)
            |> Enum.filter(&(&1.currency.code == account.currency_code))
            |> Enum.sort_by(& &1.id, :desc)
            |> Enum.map(
              &(&1
                |> Charges.charge_json()
                |> Map.delete("overdueInstallmentCharge")
                |> month_day_pair())
            )
        }
      end)
    end)
  end

  # here a day of the year is an array of the month and the day, not the text a charge's own page gives
  defp month_day_pair(
         %{"feeOnMonthDay" => "--" <> <<m::binary-size(2), "-", d::binary-size(2)>>} = charge
       ),
       do: %{charge | "feeOnMonthDay" => [String.to_integer(m), String.to_integer(d)]}

  defp month_day_pair(charge), do: charge

  @doc "`GET /savingsaccounts/:id/charges/:charge_id`"
  def show(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      associations =
        case conn.query_params["associations"] do
          nil -> []
          text -> text |> String.split(",") |> Enum.map(&String.trim/1)
        end

      Read.respond(conn, @resource, fn -> one(id, charge_id, associations) end)
    end)
  end

  defp one(id, charge_id, associations) do
    account = Savings.fetch!(id)

    case AccountCharges.get(id, charge_id) do
      nil -> {:error, AccountCharges.not_found_on_read(id)}
      charge -> with_transactions(json(charge, account), charge, associations)
    end
  end

  defp with_transactions(body, charge, associations) do
    if Enum.any?(associations, &(&1 in ["transactions", "all"])),
      do: Map.put(body, "transactions", transactions(charge.id)),
      else: body
  end

  # the account and the charge named in a path
  defp with_ids(conn, raw_id, raw_charge_id, fun) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, charge_id} <- Write.path_id(raw_charge_id) do
      fun.(id, charge_id)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "A charge as Fineract shows it."
  @spec json(map, map) :: map
  def json(c, account) do
    zero = 0

    %{
      "id" => c.id,
      "chargeId" => c.charge_id,
      "accountId" => c.account_id,
      "name" => c.name,
      "chargeTimeType" => option(Enums.time(c.time)),
      "chargeCalculationType" => option(Enums.calculation(c.calculation)),
      "percentage" => c.percentage || zero,
      "amountPercentageAppliedTo" => c.applied_to || zero,
      "currency" => SavingsAccounts.currency(account),
      "amount" => c.amount,
      "amountPaid" => c.paid || zero,
      "amountWaived" => c.waived_amount || zero,
      "amountWrittenOff" => c.written_off || zero,
      "amountOutstanding" => c.outstanding,
      "amountOrPercentage" => AccountCharges.amount_or_percentage(c),
      "penalty" => c.penalty,
      "isActive" => c.is_active,
      "isFreeWithdrawal" => c.is_free_withdrawal == true
    }
    |> put("dueDate", c.due_date)
    |> put("feeOnMonthDay", month_day(c))
    |> put("feeInterval", c.fee_interval)
    |> put("inactivationDate", c.inactivated_on_date)
  end

  @doc "A charge as an account shows it among its associations: with what kind of charge it is."
  @spec account_json(map, map) :: map
  def account_json(c, account) do
    c
    |> json(account)
    |> put("feeOnMonthDay", month_day_text(c))
    |> Map.merge(%{
      "savingsActivation" => AccountCharges.activation?(c),
      "withdrawalFee" => AccountCharges.withdrawal_fee?(c),
      "feeCharge" => not c.penalty,
      "annualFee" => AccountCharges.annual?(c)
    })
  end

  # an account's own page writes the day of the year as text
  defp month_day_text(%{fee_on_month: month, fee_on_day: day})
       when not is_nil(month) and not is_nil(day),
       do:
         "--" <>
           String.pad_leading("#{month}", 2, "0") <> "-" <> String.pad_leading("#{day}", 2, "0")

  defp month_day_text(_charge), do: nil

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp month_day(%{fee_on_month: month, fee_on_day: day})
       when not is_nil(month) and not is_nil(day),
       do: [month, day]

  defp month_day(_charge), do: nil

  defp option(option), do: Read.option(option)

  # what was paid or waived of the charge, with the transactions that did it
  defp transactions(charge_id) do
    from(p in "m_savings_account_charge_paid_by",
      join: t in "m_savings_account_transaction",
      on: t.id == p.savings_account_transaction_id,
      where: p.savings_account_charge_id == ^charge_id,
      order_by: p.id,
      select: %{
        transaction_id: t.id,
        allocation_id: p.id,
        date: t.transaction_date,
        type: t.transaction_type_enum,
        amount: t.amount,
        allocated: p.amount,
        reversed: t.is_reversed
      }
    )
    |> TenantRepo.all()
    |> Enum.map(fn t ->
      %{
        "transactionId" => t.transaction_id,
        "allocationId" => t.allocation_id,
        "date" => t.date,
        "transactionType" =>
          ECBApiFineract.Resources.SavingsTransactions.type_json(t.type, false),
        "amount" => t.amount,
        "amountAllocated" => t.allocated,
        "reversed" => t.reversed
      }
    end)
  end

  # --- writes ---------------------------------------------------------------------------------

  @doc "`POST /savingsaccounts/:id/charges`"
  def create(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "CREATE", id: &1))

  @doc "`PUT /savingsaccounts/:id/charges/:charge_id`"
  def update(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      Write.execute(conn, @resource, "UPDATE", id: id, subentity_id: charge_id)
    end)
  end

  @doc "`DELETE /savingsaccounts/:id/charges/:charge_id`"
  def delete(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      Write.execute(conn, @resource, "DELETE", id: id, subentity_id: charge_id)
    end)
  end

  @doc "`POST /savingsaccounts/:id/charges/:charge_id?command=paycharge|waive|inactivate`"
  def command(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      command = conn.query_params["command"]

      case command && Map.fetch(@commands, String.downcase(String.trim(command))) do
        {:ok, action} ->
          Write.execute(conn, @resource, action, id: id, subentity_id: charge_id)

        _ ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: command,
            allowed: ["paycharge", "waive", "inactivate"]
          })
      end
    end)
  end
end
