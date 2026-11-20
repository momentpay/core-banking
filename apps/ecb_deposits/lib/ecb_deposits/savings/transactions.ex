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
         t.release_id_of_hold_amount, t.payment_detail_id, t.ref_no, u.username AS submitted_by_username, n.note,
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
