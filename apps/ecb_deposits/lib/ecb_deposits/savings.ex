defmodule ECBDeposits.Savings do
  @moduledoc """
  Savings accounts (`m_savings_account`), the read side, following Fineract's `SavingsAccountReadPlatformServiceImpl`.

  An account is opened from a savings product, copying what it needs of it, and passes through submitted, approved,
  active and closed (or rejected, or withdrawn by the applicant). Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @pending 100
  @approved 200
  @active 300
  @withdrawn 400
  @rejected 500
  @closed 600

  @doc "The status numbers: `:pending`, `:approved`, `:active`, `:withdrawn`, `:rejected`, `:closed`."
  @spec status(atom) :: integer
  def status(:pending), do: @pending
  def status(:approved), do: @approved
  def status(:active), do: @active
  def status(:withdrawn), do: @withdrawn
  def status(:rejected), do: @rejected
  def status(:closed), do: @closed

  @select """
  SELECT a.id, a.account_no, a.external_id, a.client_id, c.display_name AS client_name, c.office_id AS client_office_id,
         c.activation_date AS client_activation_date, a.group_id, a.product_id, p.name AS product_name,
         a.field_officer_id, s.display_name AS field_officer_name, a.status_enum, a.sub_status_enum,
         a.account_type_enum, a.deposit_type_enum,
         a.submittedon_date, a.submittedon_userid, a.approvedon_date, a.approvedon_userid, a.rejectedon_date,
         a.rejectedon_userid, a.withdrawnon_date, a.withdrawnon_userid, a.activatedon_date, a.activatedon_userid,
         a.closedon_date, a.closedon_userid,
         a.currency_code, a.currency_digits, a.currency_multiplesof, cur.name AS currency_name,
         cur.display_symbol AS currency_symbol, cur.internationalized_name_code AS currency_name_code,
         a.nominal_annual_interest_rate, a.interest_compounding_period_enum, a.interest_posting_period_enum,
         a.interest_calculation_type_enum, a.interest_calculation_days_in_year_type_enum,
         a.min_required_opening_balance, a.lockin_period_frequency, a.lockin_period_frequency_enum,
         a.withdrawal_fee_for_transfer, a.allow_overdraft, a.overdraft_limit, a.nominal_annual_interest_rate_overdraft,
         a.min_overdraft_for_interest_calculation, a.lockedin_until_date_derived,
         a.total_deposits_derived, a.total_withdrawals_derived, a.total_interest_posted_derived,
         a.total_overdraft_interest_derived, a.account_balance_derived, a.min_required_balance,
         a.enforce_min_required_balance, a.min_balance_for_interest_calculation, a.withhold_tax, a.tax_group_id,
         a.is_lien_allowed, a.max_allowed_lien_limit, a.on_hold_funds_derived, a.version,
         a.start_interest_calculation_date, p.is_dormancy_tracking_active AS dormancy_tracking_active,
         p.accounting_type AS accounting_type,
         (SELECT max(x.transaction_date) FROM m_savings_account_transaction x
           WHERE x.savings_account_id = a.id AND NOT x.is_reversed AND NOT x.is_reversal) AS last_transaction_date
  FROM m_savings_account a
  LEFT JOIN m_client c ON c.id = a.client_id
  LEFT JOIN m_savings_product p ON p.id = a.product_id
  LEFT JOIN m_staff s ON s.id = a.field_officer_id
  LEFT JOIN m_currency cur ON cur.code = a.currency_code
  """

  @doc "One account, or `nil`."
  @spec get(integer) :: map | nil
  def get(id), do: one("WHERE a.id = $1", [id])

  @doc "The account with this external id, or `nil`."
  @spec get_by_external_id(String.t()) :: map | nil
  def get_by_external_id(external_id), do: one("WHERE a.external_id = $1", [external_id])

  @doc "One account or the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id), do: get(id) || raise(not_found(id))

  @doc "The not-found error for an account number."
  @spec not_found(term) :: Exception.t()
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.saving.account.id.invalid",
        "Savings account with identifier #{id} does not exist",
        [id]
      )

  @doc "The not-found error for an external id on the transaction routes, which do name it."
  @spec not_found_by_external_id_named(term) :: Exception.t()
  def not_found_by_external_id_named(external_id),
    do:
      ResourceNotFound.new(
        "error.msg.saving.account.id.invalid",
        "Savings account with external identifier #{external_id} does not exist",
        [external_id]
      )

  @doc "The not-found error for an external id; Fineract names no identifier."
  @spec not_found_by_external_id(term) :: Exception.t()
  def not_found_by_external_id(_external_id),
    do:
      ResourceNotFound.new(
        "error.msg.saving.account.id.invalid",
        "Savings account with identifier null does not exist",
        [nil]
      )

  @doc """
  The accounts that match the filters (`:external_id`, `:client_id`, `:account_no`) in the order asked for
  (`:order_by`, `:sort`), a page of them (`:limit`, `:offset`) and how many there were without the page.
  """
  @spec list(keyword) :: {non_neg_integer, [map]}
  def list(opts \\ []) do
    {where, params} = filters(opts)
    order = order(opts[:order_by], opts[:sort])

    %{rows: [[total]]} =
      TenantRepo.query!("SELECT count(*) FROM m_savings_account a" <> where, params)

    {limit, offset} = {opts[:limit], opts[:offset]}

    paging =
      [if(limit, do: " LIMIT #{limit}"), if(offset, do: " OFFSET #{offset}")]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    {total, query(where <> order <> paging, params)}
  end

  defp filters(opts) do
    [
      {opts[:external_id], "a.external_id = "},
      {opts[:client_id], "a.client_id = "},
      {opts[:account_no], "a.account_no = "}
    ]
    |> Enum.reject(fn {value, _} -> is_nil(value) end)
    |> Enum.with_index(1)
    |> Enum.reduce({"", []}, fn {{value, clause}, i}, {sql, params} ->
      {sql <> if(sql == "", do: " WHERE ", else: " AND ") <> clause <> "$#{i}", params ++ [value]}
    end)
  end

  @orderings ~w(id accountNo externalId clientId savingsProductId status)
  @columns %{
    "id" => "a.id",
    "accountNo" => "a.account_no",
    "externalId" => "a.external_id",
    "clientId" => "a.client_id",
    "savingsProductId" => "a.product_id",
    "status" => "a.status_enum"
  }

  defp order(by, sort) when by in @orderings,
    do: " ORDER BY " <> Map.fetch!(@columns, by) <> direction(sort)

  defp order(_by, _sort), do: " ORDER BY a.id"

  defp direction(sort) when sort in ["desc", "DESC"], do: " DESC"
  defp direction(_), do: " ASC"

  defp one(tail, params), do: tail |> query(params) |> List.first()

  defp query(tail, params) do
    %{columns: columns, rows: rows} = TenantRepo.query!(@select <> tail, params)
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
  end

  @doc "The users with these ids, by id, as `%{username, firstname, lastname}`."
  @spec users([integer | nil]) :: %{integer => map}
  def users(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(u in "m_appuser",
      where: u.id in ^ids,
      select: {u.id, %{username: u.username, firstname: u.firstname, lastname: u.lastname}}
    )
    |> TenantRepo.all()
    |> Map.new()
  end
end
