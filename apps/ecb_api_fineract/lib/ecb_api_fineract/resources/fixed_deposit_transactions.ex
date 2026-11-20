defmodule ECBApiFineract.Resources.FixedDepositTransactions do
  @moduledoc """
  `/v1/fixeddepositaccounts/:id/transactions`: the transactions of a fixed deposit account. The list, one transaction
  and the template, as Fineract's `FixedDepositAccountTransactionsApiResource` answers them. A deposit or a
  correction is refused as not supported yet and a withdrawal is not allowed, which is what Fineract answers.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Read, SavingsTransactions, Write}
  alias ECBDeposits.DepositAccounts
  alias ECBDeposits.Savings.Transactions
  alias ECBPlatform.Errors.UnrecognizedQueryParameter

  @resource "FIXEDDEPOSITACCOUNT"

  @doc "`GET /fixeddepositaccounts/:id/transactions`: nothing for an account that is not there"
  def index(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> list(DepositAccounts.get(:fixed, id)) end)
    end)
  end

  defp list(nil), do: []
  defp list(a), do: a |> SavingsTransactions.compact_list_json() |> Enum.map(&shape(&1, a))

  @doc "`GET /fixeddepositaccounts/:id/transactions/:transaction_id`"
  def show(conn, raw_id, raw_tid) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, tid} <- Write.path_id(raw_tid) do
      Read.respond(conn, @resource, fn -> one(id, tid, conn.query_params) end)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp one(id, tid, q) do
    a = DepositAccounts.get(:fixed, id)
    tx = a && Transactions.get(id, tid)
    if tx == nil, do: raise(Transactions.not_found(id, tid))

    body =
      a |> SavingsTransactions.compact_list_json() |> Enum.find(&(&1["id"] == tx.id)) |> shape(a)

    if q["template"] == "true",
      do: Map.put(body, "paymentTypeOptions", SavingsTransactions.payment_type_options()),
      else: body
  end

  @doc "`GET /fixeddepositaccounts/:id/transactions/template`"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        a = DepositAccounts.fetch!(:fixed, id)

        a
        |> SavingsTransactions.template_json()
        |> Map.update!("currency", &Map.put(&1, "inMultiplesOf", a.currency_multiplesof))
      end)
    end)
  end

  # a deposit's transactions show the multiple of their currency and leave out what they have not
  defp shape(json, a) do
    json
    |> Map.update!("currency", &Map.put(&1, "inMultiplesOf", a.currency_multiplesof))
    |> Map.reject(fn {_key, value} -> value in [nil, :null] end)
  end

  @commands %{"deposit" => "DEPOSIT", "withdrawal" => "WITHDRAWAL"}

  @doc "`POST /fixeddepositaccounts/:id/transactions?command=deposit|withdrawal`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      key = name(conn)

      if Map.has_key?(@commands, key),
        do: Write.execute(conn, @resource, Map.fetch!(@commands, key), id: id),
        else: unknown(conn, ["deposit", "withdrawal"])
    end)
  end

  @adjust %{"undo" => "UNDOTRANSACTION", "modify" => "ADJUSTTRANSACTION"}

  @doc "`POST /fixeddepositaccounts/:id/transactions/:transaction_id?command=undo|modify`"
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
