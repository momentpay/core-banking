defmodule ECBLedger.Journal do
  @moduledoc """
  Journal entries (`acc_gl_journal_entry`), read side, following Fineract's
  `JournalEntryReadPlatformServiceImpl`.

  An entry is one debit or credit of an amount against one account of one office on one date. The entries
  of one transaction share a transaction id and balance to zero. Must run inside a tenant scope.

  Fineract's default order is entry date, then id. `orderBy` takes a column name Fineract's query exposes
  (`amount`, `transactionDate`, `journalEntry.id`, ...); anything else is a server error there, as here.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @credit 1
  @debit 2

  # the names `orderBy` may use, mapped to what they sort by
  @sortable ~w(id transactionId glAccountName glAccountCode glAccountId officeId officeName
               referenceNumber manualEntry transactionDate entryType amount entityType entityId
               createdByUserId createdByUserName comments submittedOnDate reversed currencyCode)
  @sortable_columns Map.new(
                      ~w(id account_id office_id transaction_id entry_date type_enum amount description
                         reversed manual_entry ref_num submitted_on_date currency_code entity_type_enum
                         entity_id created_by),
                      &{&1, String.to_atom(&1)}
                    )

  @doc "The entry type id of a credit."
  def credit, do: @credit

  @doc "The entry type id of a debit."
  def debit, do: @debit

  @doc """
  An entry type as `%{id, code, value}`. Fineract's code for a debit has a typo (`journalEntrytType.debit`)
  that clients see, so it is kept.
  """
  @spec entry_type(integer) :: map
  def entry_type(@credit), do: %{id: @credit, code: "journalEntryType.credit", value: "CREDIT"}
  def entry_type(@debit), do: %{id: @debit, code: "journalEntrytType.debit", value: "DEBIT"}

  @doc """
  The entries matching the filters, and how many match in all.

  Filters: `:transaction_id`, `:entity_type` (ignored when `:manual_only` is given, as in Fineract),
  `:manual_only` (`true` keeps manual entries, `false` keeps all), `:office_id`, `:currency_code`,
  `:gl_account_id`, `:from_date`, `:to_date`, `:submitted_from`, `:submitted_to`, `:loan_id`, `:savings_id`, and the page:
  `:limit` (a limit of 0 or less means no limit), `:offset` (only with a limit), `:order_by`, `:sort_order`.
  """
  @spec list(keyword) :: %{total: non_neg_integer, items: [map]}
  def list(filters \\ []) do
    filtered = base() |> where(^conditions(filters))

    total = TenantRepo.aggregate(filtered, :count)

    items =
      filtered
      |> select(^selection())
      |> order(filters[:order_by], filters[:sort_order])
      |> page(filters[:limit], filters[:offset])
      |> TenantRepo.all()
      |> Enum.map(&finish/1)

    %{total: total, items: items}
  end

  @doc "One entry, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([j], j.id == ^id) |> select(^selection()) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc """
  The entries of a transaction that can be reversed: manual and not yet reversed, in id order. A reversal
  has no entries to reverse once it is made, so a second attempt finds none.
  """
  @spec reversible(String.t()) :: [map]
  def reversible(transaction_id) do
    from(j in "acc_gl_journal_entry",
      where:
        j.transaction_id == ^transaction_id and j.reversed == false and j.manual_entry == true,
      order_by: j.id,
      select: %{
        id: j.id,
        account_id: j.account_id,
        office_id: j.office_id,
        currency_code: j.currency_code,
        transaction_id: j.transaction_id,
        entry_date: j.entry_date,
        type: j.type_enum,
        amount: j.amount,
        reference_number: j.ref_num,
        payment_details_id: j.payment_details_id,
        loan_transaction_id: j.loan_transaction_id,
        savings_transaction_id: j.savings_transaction_id,
        client_transaction_id: j.client_transaction_id,
        share_transaction_id: j.share_transaction_id
      }
    )
    |> TenantRepo.all()
  end

  @doc "True when the account has any entry (an account that was posted to cannot be deleted)."
  @spec posted?(integer) :: boolean
  def posted?(account_id),
    do: TenantRepo.exists?(from(j in "acc_gl_journal_entry", where: j.account_id == ^account_id))

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.journalEntries.id.invalid",
        "Journal Entry with entry Id #{id} does not exist ",
        [id]
      )

  @doc false
  def transaction_not_found(transaction_id),
    do:
      ResourceNotFound.new(
        "error.msg.journalEntries.transactionId.invalid",
        "Journal Entries with transaction Identifier #{transaction_id} does not exist or are not system generated/reversible ",
        [transaction_id]
      )

  # --- the query ------------------------------------------------------------------------------

  defp base do
    from(j in "acc_gl_journal_entry",
      left_join: a in "acc_gl_account",
      on: a.id == j.account_id,
      left_join: o in "m_office",
      on: o.id == j.office_id,
      left_join: u in "m_appuser",
      on: u.id == j.created_by,
      join: c in "m_currency",
      on: c.code == j.currency_code,
      left_join: pd in "m_payment_detail",
      on: pd.id == j.payment_details_id,
      left_join: pt in "m_payment_type",
      on: pt.id == pd.payment_type_id
    )
  end

  defp selection do
    dynamic(
      [j, a, o, u, c, pd, pt],
      %{
        id: j.id,
        transaction_id: j.transaction_id,
        gl_account_id: a.id,
        gl_account_name: a.name,
        gl_code: a.gl_code,
        classification: a.classification_enum,
        office_id: j.office_id,
        office_name: o.name,
        reference_number: j.ref_num,
        manual_entry: j.manual_entry,
        transaction_date: j.entry_date,
        type: j.type_enum,
        amount: j.amount,
        entity_type: j.entity_type_enum,
        entity_id: j.entity_id,
        created_by_user_id: u.id,
        created_by_username: u.username,
        comments: j.description,
        submitted_on_date: j.submitted_on_date,
        reversed: j.reversed,
        currency: %{
          code: c.code,
          name: c.name,
          decimal_places: c.decimal_places,
          multiples_of: c.currency_multiplesof,
          display_symbol: c.display_symbol,
          name_code: c.internationalized_name_code
        },
        running_balance_computed: j.is_running_balance_calculated,
        office_running_balance: j.office_running_balance,
        organization_running_balance: j.organization_running_balance,
        payment: %{
          type_id: pd.payment_type_id,
          type_name: pt.value,
          account_number: pd.account_number,
          check_number: pd.check_number,
          routing_code: pd.routing_code,
          receipt_number: pd.receipt_number,
          bank_number: pd.bank_number
        }
      }
    )
  end

  defp finish(row) do
    payment = if row.payment.type_id, do: row.payment, else: nil
    row |> Map.put(:payment, payment) |> Map.update!(:entity_type, &entity_type/1)
  end

  # the product an entry came from (`PortfolioProductType`), as `%{id, code, value}`
  @products [
    {1, "productType.loan", "LOAN"},
    {2, "productType.saving", "SAVING"},
    {3, "productType.provisioning", "PROVISIONING"},
    {4, "productType.shares", "SHARES"},
    {5, "productType.client", "CLIENT"},
    {6, "productType.workingCapitalLoan", "WORKING CAPITAL LOAN"}
  ]

  defp entity_type(nil), do: nil

  defp entity_type(id) do
    case List.keyfind(@products, id, 0) do
      {id, code, value} -> %{id: id, code: code, value: value}
      nil -> nil
    end
  end

  # --- filters --------------------------------------------------------------------------------

  defp conditions(filters) do
    [
      transaction_id(filters[:transaction_id]),
      entity_type(filters[:entity_type], filters[:manual_only]),
      office(filters[:office_id]),
      currency(filters[:currency_code]),
      account(filters[:gl_account_id]),
      dates(filters[:from_date], filters[:to_date]),
      submitted(filters),
      manual(filters[:manual_only]),
      loan(filters[:loan_id]),
      savings(filters[:savings_id])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(dynamic(true), fn condition, all -> dynamic(^all and ^condition) end)
  end

  defp transaction_id(id) when id in [nil, ""], do: nil
  defp transaction_id(id), do: dynamic([j], j.transaction_id == ^id)

  # `entityType` only counts when `manualEntriesOnly` was not given at all
  defp entity_type(type, nil) when is_integer(type) and type != 0,
    do: dynamic([j], j.entity_type_enum == ^type)

  defp entity_type(_type, _manual), do: nil

  defp office(nil), do: nil
  defp office(id), do: dynamic([j], j.office_id == ^id)

  defp currency(code) when code in [nil, ""], do: nil
  defp currency(code), do: dynamic([j], j.currency_code == ^code)

  defp account(id) when id in [nil, 0], do: nil
  defp account(id), do: dynamic([j], j.account_id == ^id)

  defp dates(nil, nil), do: nil
  defp dates(from, nil), do: dynamic([j], j.entry_date >= ^from)
  defp dates(nil, to), do: dynamic([j], j.entry_date <= ^to)
  defp dates(from, to), do: dynamic([j], j.entry_date >= ^from and j.entry_date <= ^to)

  # Fineract tests `fromDate` where it should test `submittedOnDateFrom`, so a lone `submittedOnDateFrom`
  # compares with a missing upper bound and matches nothing. It is kept.
  defp submitted(filters),
    do: submitted(filters[:submitted_from], filters[:submitted_to], filters[:from_date])

  defp submitted(nil, nil, _from_date), do: nil

  defp submitted(from, to, _from_date) when from != nil and to != nil,
    do: dynamic([j], j.submitted_on_date >= ^from and j.submitted_on_date <= ^to)

  defp submitted(from, _to, from_date) when from_date != nil and from != nil,
    do: dynamic([j], j.submitted_on_date >= ^from)

  defp submitted(_from, to, from_date) when from_date == nil and to != nil,
    do: dynamic([j], j.submitted_on_date <= ^to)

  defp submitted(_from, _to, _from_date), do: dynamic(false)

  defp manual(true), do: dynamic([j], j.manual_entry == true)
  defp manual(_other), do: nil

  # Loan and savings transactions belong to products that are not built yet: until their tables exist
  # there is nothing an entry could belong to.
  defp loan(nil), do: nil

  defp loan(id) do
    if table?("m_loan_transaction"),
      do:
        dynamic(
          [j],
          j.loan_transaction_id in subquery(
            from(t in "m_loan_transaction", where: t.loan_id == ^id, select: t.id)
          )
        ),
      else: dynamic(false)
  end

  defp savings(nil), do: nil

  defp savings(id) do
    if table?("m_savings_account_transaction"),
      do:
        dynamic(
          [j],
          j.savings_transaction_id in subquery(
            from(t in "m_savings_account_transaction",
              where: t.savings_account_id == ^id,
              select: t.id
            )
          )
        ),
      else: dynamic(false)
  end

  defp table?(name),
    do:
      TenantRepo.exists?(
        from(t in "tables",
          prefix: "information_schema",
          where: t.table_name == ^name and t.table_schema == "public"
        )
      )

  # --- order and page -------------------------------------------------------------------------

  defp order(query, order_by, sort_order) when order_by in [nil, ""] do
    _ = sort_order
    order_by(query, [j], asc: j.entry_date, asc: j.id)
  end

  defp order(query, order_by, sort_order) do
    direction = direction(sort_order)
    expression = sort_expression(String.trim(order_by))
    order_by(query, ^[{direction, expression}])
  end

  defp direction(nil), do: :asc
  defp direction(""), do: :asc

  defp direction(text) do
    case String.downcase(String.trim(text)) do
      "asc" -> :asc
      "desc" -> :desc
      _ -> raise ECBLedger.Errors.InvalidOrderBy, value: text
    end
  end

  defp sort_expression(name) when name in @sortable, do: by_alias(name)

  defp sort_expression("journalEntry." <> column) when is_map_key(@sortable_columns, column),
    do: dynamic([j], field(j, ^Map.fetch!(@sortable_columns, column)))

  defp sort_expression(name), do: raise(ECBLedger.Errors.InvalidOrderBy, value: name)

  defp by_alias("id"), do: dynamic([j], j.id)
  defp by_alias("transactionId"), do: dynamic([j], j.transaction_id)
  defp by_alias("glAccountName"), do: dynamic([_j, a], a.name)
  defp by_alias("glAccountCode"), do: dynamic([_j, a], a.gl_code)
  defp by_alias("glAccountId"), do: dynamic([_j, a], a.id)
  defp by_alias("officeId"), do: dynamic([j], j.office_id)
  defp by_alias("officeName"), do: dynamic([_j, _a, o], o.name)
  defp by_alias("referenceNumber"), do: dynamic([j], j.ref_num)
  defp by_alias("manualEntry"), do: dynamic([j], j.manual_entry)
  defp by_alias("transactionDate"), do: dynamic([j], j.entry_date)
  defp by_alias("entryType"), do: dynamic([j], j.type_enum)
  defp by_alias("amount"), do: dynamic([j], j.amount)
  defp by_alias("entityType"), do: dynamic([j], j.entity_type_enum)
  defp by_alias("entityId"), do: dynamic([j], j.entity_id)
  defp by_alias("createdByUserId"), do: dynamic([_j, _a, _o, u], u.id)
  defp by_alias("createdByUserName"), do: dynamic([_j, _a, _o, u], u.username)
  defp by_alias("comments"), do: dynamic([j], j.description)
  defp by_alias("submittedOnDate"), do: dynamic([j], j.submitted_on_date)
  defp by_alias("reversed"), do: dynamic([j], j.reversed)
  defp by_alias("currencyCode"), do: dynamic([j], j.currency_code)

  defp page(query, limit, offset) when is_integer(limit) and limit > 0 do
    query = limit(query, ^limit)
    if is_integer(offset) and offset > 0, do: offset(query, ^offset), else: query
  end

  defp page(query, _limit, _offset), do: query
end
