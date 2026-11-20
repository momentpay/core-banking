defmodule ECBDeposits.Savings.Transactions do
  @moduledoc """
  The transactions of a savings account (`m_savings_account_transaction`), the read side, after Fineract's
  `SavingsAccountTransactionsMapper`. Must run inside a tenant scope.
  """
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @deposit 1
  @withdrawal 2

  @doc "The transaction types: `:deposit` and `:withdrawal`."
  @spec type(atom) :: integer
  def type(:deposit), do: @deposit
  def type(:withdrawal), do: @withdrawal

  @select """
  SELECT t.id, t.savings_account_id, t.transaction_type_enum, t.is_reversed, t.transaction_date, t.amount,
         t.overdraft_amount_derived, t.running_balance_derived, t.is_reversal, t.original_transaction_id,
         t.submitted_on_date, t.external_id, t.created_by, t.is_manual, t.is_lien_transaction,
         t.release_id_of_hold_amount, t.reason_for_block, t.payment_detail_id, t.ref_no, u.username AS submitted_by_username, n.note,
         pd.payment_type_id, pt.value AS payment_type_name, pd.account_number, pd.check_number, pd.routing_code,
         pd.receipt_number, pd.bank_number
  FROM m_savings_account_transaction t
  LEFT JOIN m_payment_detail pd ON pd.id = t.payment_detail_id
  LEFT JOIN m_payment_type pt ON pt.id = pd.payment_type_id
  LEFT JOIN m_appuser u ON u.id = t.created_by
  LEFT JOIN m_note n ON n.savings_account_transaction_id = t.id
  """

  @doc "One transaction of the account, or `nil`."
  @spec get(integer, integer) :: map | nil
  def get(account_id, id),
    do: "WHERE t.savings_account_id = $1 AND t.id = $2" |> query([account_id, id]) |> List.first()

  @doc "The transaction of the account with this external id, or `nil`."
  @spec get_by_external_id(integer, String.t()) :: map | nil
  def get_by_external_id(account_id, external_id),
    do:
      "WHERE t.savings_account_id = $1 AND t.external_id = $2"
      |> query([account_id, external_id])
      |> List.first()

  @doc "Every transaction of the account, the latest date first and the latest id first within a date."
  @spec list(integer) :: [map]
  def list(account_id),
    do:
      "WHERE t.savings_account_id = $1 ORDER BY t.transaction_date DESC, t.id DESC"
      |> query([account_id])

  # the types a search can ask for (all of Fineract's but the invalid one), and which of them take money in or out
  @all_types [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]
  @credit_entry [1, 3, 8, 21]
  @debit_entry [2, 4, 5, 7, 17, 18, 19, 20]

  @doc """
  Searches the transactions of an account (reversed ones included, the reversals themselves not), after Fineract's
  `SavingsAccountTransactionsSearchServiceImpl`. `filters` may have `from_date`, `to_date`, `from_submitted`,
  `to_submitted`, `from_amount`, `to_amount`, `types` (a list of the text of ids), `credit` and `debit`; `sort` is a list
  of `{column, :asc | :desc}` (the default is newest first); `page` and `size` say which. Answers `{total, rows}`.
  """
  @spec search(integer, map, [{String.t(), :asc | :desc}] | nil, non_neg_integer, pos_integer) ::
          {non_neg_integer, [map]}
  def search(account_id, filters, sort, page, size) do
    case type_filter(filters) do
      :none -> {0, []}
      types -> run_search(account_id, filters, types, sort, page, size)
    end
  end

  defp run_search(account_id, filters, types, sort, page, size) do
    {where, params} =
      [
        {"t.transaction_date >= ", filters[:from_date]},
        {"t.transaction_date <= ", filters[:to_date]},
        {"t.submitted_on_date >= ", filters[:from_submitted]},
        {"t.submitted_on_date <= ", filters[:to_submitted]},
        {"t.amount >= ", filters[:from_amount]},
        {"t.amount <= ", filters[:to_amount]}
      ]
      |> Enum.reject(fn {_, value} -> value == nil end)
      |> Enum.reduce({["t.savings_account_id = $1", "NOT t.is_reversal"], [account_id]}, fn
        {sql, value}, {clauses, params} ->
          {clauses ++ [sql <> "$#{length(params) + 1}"], params ++ [value]}
      end)

    {where, params} =
      if types == nil,
        do: {where, params},
        else:
          {where ++ ["t.transaction_type_enum = ANY($#{length(params) + 1})"], params ++ [types]}

    clause = " WHERE " <> Enum.join(where, " AND ")

    %{rows: [[total]]} =
      TenantRepo.query!(
        "SELECT count(*) FROM m_savings_account_transaction t" <> clause,
        params
      )

    if total == 0 do
      {0, []}
    else
      order =
        (sort || [{"transaction_date", :desc}, {"created_on_utc", :desc}, {"id", :desc}])
        |> Enum.map_join(", ", fn {column, dir} -> "t.#{column} #{dir}" end)

      tail = "#{clause} ORDER BY #{order}, t.id LIMIT #{size} OFFSET #{page * size}"
      {total, query(tail, params)}
    end
  end

  # the types the filters of credit, debit and types leave: `nil` for no restriction, `:none` for no type at all
  defp type_filter(filters) do
    types = Map.get(filters, :types)
    named = if types, do: fn t -> Integer.to_string(t) in types end

    case Enum.filter([entry_filter(filters[:credit], filters[:debit]), named], & &1) do
      [] -> nil
      predicates -> types_passing(predicates)
    end
  end

  defp types_passing(predicates) do
    case Enum.filter(@all_types, fn t -> Enum.all?(predicates, & &1.(t)) end) do
      [] -> :none
      ids -> ids
    end
  end

  # the filter of credit and debit: each alone, or both: either when both are asked for, else both must hold
  defp entry_filter(nil, nil), do: nil
  defp entry_filter(credit, nil), do: fn t -> t in @credit_entry == credit end
  defp entry_filter(nil, debit), do: fn t -> t in @debit_entry == debit end

  defp entry_filter(credit, debit) do
    by_credit = entry_filter(credit, nil)
    by_debit = entry_filter(nil, debit)

    if credit and debit,
      do: fn t -> by_credit.(t) or by_debit.(t) end,
      else: fn t -> by_credit.(t) and by_debit.(t) end
  end

  @doc "The columns a search can sort on."
  @spec columns() :: [String.t()]
  def columns do
    %{rows: rows} =
      TenantRepo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'm_savings_account_transaction'",
        []
      )

    Enum.map(rows, &hd/1)
  end

  @doc "The error for a transaction the account does not have."
  @spec not_found(integer, term) :: Exception.t()
  def not_found(account_id, id),
    do:
      ResourceNotFound.new(
        "error.msg.saving.account.trasaction.id.invalid",
        "Savings account with savings identifier #{account_id} and trasaction identifier #{id} does not exist",
        [account_id, id]
      )

  @doc "The error for a transaction with this external id the account does not have."
  @spec not_found_by_external_id(integer, String.t()) :: Exception.t()
  def not_found_by_external_id(account_id, external_id),
    do:
      ResourceNotFound.new(
        "error.msg.saving.account.trasaction.external.id.invalid",
        "Savings account with savings identifier #{account_id} and trasaction external identifier #{external_id} does not exist",
        [account_id, external_id]
      )

  defp query(tail, params) do
    %{columns: columns, rows: rows} = TenantRepo.query!(@select <> tail, params)
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
  end
end
