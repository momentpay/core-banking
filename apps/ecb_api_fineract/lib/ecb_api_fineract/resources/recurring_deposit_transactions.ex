defmodule ECBApiFineract.Resources.RecurringDepositTransactions do
  @moduledoc """
  `/v1/recurringdepositaccounts/:id/transactions`: the transactions of a recurring deposit account. One transaction,
  the template of a deposit or a withdrawal (a deposit of what the next installment still needs, on the day it falls
  due), and making a deposit or a withdrawal, as Fineract's `RecurringDepositAccountTransactionsApiResource` answers
  them. The list of transactions is not a route of Fineract's, whose web container answers 405.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Read, SavingsTransactions, Write}
  alias ECBDeposits.DepositAccounts
  alias ECBDeposits.DepositAccounts.Recurring
  alias ECBDeposits.Savings.Transactions
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Errors.UnrecognizedQueryParameter

  @resource "RECURRINGDEPOSITACCOUNT"

  @doc "`GET /recurringdepositaccounts/:id/transactions`: Fineract has no such route for GET"
  def method_not_allowed(conn), do: Errors.spring(conn, 405, "Method Not Allowed")

  # --- reads ------------------------------------------------------------------------------------------

  @doc "`GET /recurringdepositaccounts/:id/transactions/:transaction_id`"
  def show(conn, raw_id, raw_tid) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, tid} <- Write.path_id(raw_tid) do
      Read.respond(conn, @resource, fn -> one(id, tid, conn.query_params) end)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp one(id, tid, q) do
    a = DepositAccounts.get(:recurring, id)
    tx = a && Transactions.get(id, tid)
    if tx == nil, do: raise(Transactions.not_found(id, tid))

    body =
      a
      |> SavingsTransactions.compact_list_json()
      |> Enum.find(&(&1["id"] == tx.id))
      |> shape(a)

    # with the template the answer is made anew, and knows nothing of reversals
    if q["template"] == "true",
      do:
        body
        |> Map.drop(~w(isReversal originalTransactionId releaseTransactionId reasonForBlock))
        |> Map.put("paymentTypeOptions", SavingsTransactions.payment_type_options()),
      else: body
  end

  # a deposit's transactions show the multiple of their currency and leave out what they have not, and their notes
  defp shape(json, a) do
    json
    |> Map.delete("note")
    |> Map.update!("currency", &Map.put(&1, "inMultiplesOf", a.currency_multiplesof))
    |> Map.reject(fn {_key, value} -> value in [nil, :null] end)
  end

  @doc "`GET /recurringdepositaccounts/:id/transactions/template?command=deposit|withdrawal`"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> template_json(id, name(conn)) end)
    end)
  end

  defp template_json(_id, command) when command not in ["deposit", "withdrawal"],
    do:
      {:error,
       %UnrecognizedQueryParameter{
         name: "command",
         value: if(command == "", do: nil, else: command),
         allowed: ["deposit", "withdrawal"]
       }}

  defp template_json(id, command) do
    a = DepositAccounts.fetch!(:recurring, id)

    # what the first installment not paid still needs, on the day it falls due
    next =
      case id |> Recurring.schedule() |> Enum.find(&(&1.completed != true)) do
        nil -> raise DepositAccounts.not_found(:recurring, id)
        installment -> installment
      end

    amount = Decimal.sub(next.amount || Decimal.new(0), next.paid || Decimal.new(0))
    withdrawal? = command == "withdrawal"

    %{
      "id" => a.id,
      "transactionType" => SavingsTransactions.type_json(if(withdrawal?, do: 2, else: 1), false),
      "entryType" => if(withdrawal?, do: "DEBIT", else: "CREDIT"),
      "accountId" => a.id,
      "accountNo" => a.account_no,
      "date" => if(withdrawal?, do: BusinessDate.current(), else: next.due),
      "currency" => a |> SavingsTransactions.template_json() |> Map.fetch!("currency"),
      "amount" => amount,
      "reversed" => false,
      "submittedOnDate" => BusinessDate.current(),
      "interestedPostedAsOn" => false,
      "isManualTransaction" => false,
      "lienTransaction" => false,
      "chargesPaidByData" => [],
      "paymentTypeOptions" => SavingsTransactions.payment_type_options(),
      "isOverdraft" => false
    }
    |> Map.update!("currency", &Map.put(&1, "inMultiplesOf", a.currency_multiplesof))
  end

  # --- writes -------------------------------------------------------------------------------------------

  @commands %{"deposit" => "DEPOSIT", "withdrawal" => "WITHDRAWAL"}

  @doc "`POST /recurringdepositaccounts/:id/transactions?command=deposit|withdrawal`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      key = name(conn)

      if Map.has_key?(@commands, key),
        do: Write.execute(conn, @resource, Map.fetch!(@commands, key), id: id),
        else: unknown(conn, ["deposit", "withdrawal"])
    end)
  end

  @adjust %{"undo" => "UNDOTRANSACTION", "modify" => "ADJUSTTRANSACTION"}

  @doc "`POST /recurringdepositaccounts/:id/transactions/:transaction_id?command=undo|modify`"
  def adjust(conn, raw_id, raw_tid) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, tid} <- Write.path_id(raw_tid) do
      key = name(conn)

      if Map.has_key?(@adjust, key),
        do: Write.execute(conn, @resource, Map.fetch!(@adjust, key), id: id, subentity_id: tid),
        else: unknown(conn, ["undo", "modify"])
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp name(conn),
    do: conn.query_params["command"] |> to_string() |> String.trim() |> String.downcase()

  defp unknown(conn, allowed),
    do:
      Errors.render(conn, %UnrecognizedQueryParameter{
        name: "command",
        value: conn.query_params["command"],
        allowed: allowed
      })
end
