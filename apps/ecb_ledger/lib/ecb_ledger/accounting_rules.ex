defmodule ECBLedger.AccountingRules do
  @moduledoc """
  Accounting rules (`acc_accounting_rule`, `acc_rule_tags`), read side, following Fineract's
  `AccountingRuleReadPlatformServiceImpl`.

  A rule is a recipe for a manual journal entry. Each side (debit and credit) is either one fixed account,
  or a set of *tags*: any account carrying one of those tags may be used. A rule can belong to an office,
  and a rule marked system-defined is kept out of the list. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.Journal
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @debit 2
  @credit 1

  @doc "The rule side that is a debit, as the number the tag table stores."
  def debit, do: @debit

  @doc "The rule side that is a credit, as the number the tag table stores."
  def credit, do: @credit

  @doc """
  The rules that are not system-defined, by id, of the offices at or below `hierarchy_pattern` (a
  `.1.%` pattern; `nil` for every office). With `associations: true` a side that uses tags lists the
  accounts those tags allow instead of the tags.
  """
  @spec list(String.t() | nil, boolean) :: [map]
  def list(hierarchy_pattern \\ nil, associations \\ false) do
    base()
    |> where([r], r.system_defined == false)
    |> hierarchy(hierarchy_pattern)
    |> order_by([r], asc: r.id)
    |> TenantRepo.all()
    |> Enum.map(&finish(&1, associations))
  end

  @doc "One rule (whatever its office, system-defined or not), or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([r], r.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row, false)}
    end
  end

  @doc "Like `get/1` but raises the error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, rule} -> rule
      {:error, error} -> raise error
    end
  end

  @doc """
  The accounts a rule allows on one side through its tags: those that carry one of the side's tags, in the
  order of the tag rows and then the account id. A side with a fixed account allows no tagged accounts.
  """
  @spec accounts_by_tag(integer, integer) :: [map]
  def accounts_by_tag(rule_id, side) do
    from(t in "acc_rule_tags",
      join: a in "acc_gl_account",
      on: a.tag_id == t.tag_id,
      where: t.acc_rule_id == ^rule_id and t.acc_type_enum == ^side,
      order_by: [asc: t.id, asc: a.id],
      select: %{id: a.id, name: a.name, gl_code: a.gl_code}
    )
    |> TenantRepo.all()
  end

  @doc "The tags of one side of a rule, as Fineract lists them: by code-value id."
  @spec tags(integer, integer) :: [map]
  def tags(rule_id, side) do
    from(t in "acc_rule_tags",
      join: cv in "m_code_value",
      on: cv.id == t.tag_id,
      where: t.acc_rule_id == ^rule_id and t.acc_type_enum == ^side,
      order_by: [asc: cv.id, asc: t.id],
      select: %{id: t.id, tag: %{id: cv.id, name: cv.code_value}, side: t.acc_type_enum}
    )
    |> TenantRepo.all()
  end

  @doc "The tag ids a rule has on one side."
  @spec tag_ids(integer, integer) :: [integer]
  def tag_ids(rule_id, side),
    do:
      TenantRepo.all(
        from(t in "acc_rule_tags",
          where: t.acc_rule_id == ^rule_id and t.acc_type_enum == ^side,
          select: t.tag_id
        )
      )

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.accounting.rule.id.invalid",
        "Accounting Rule with identifier #{id} does not exist",
        [id]
      )

  @doc "The entry type of a side as `%{id, code, value}`."
  @spec side(integer) :: map
  def side(side), do: Journal.entry_type(side)

  # --- internals ------------------------------------------------------------------------------

  defp base do
    from(r in "acc_accounting_rule",
      join: o in "m_office",
      on: o.id == r.office_id,
      left_join: d in "acc_gl_account",
      on: d.id == r.debit_account_id,
      left_join: c in "acc_gl_account",
      on: c.id == r.credit_account_id,
      select: %{
        id: r.id,
        office_id: r.office_id,
        office_name: o.name,
        name: r.name,
        description: r.description,
        system_defined: r.system_defined,
        allow_multiple_debits: r.allow_multiple_debits,
        allow_multiple_credits: r.allow_multiple_credits,
        debit_account_id: r.debit_account_id,
        credit_account_id: r.credit_account_id,
        debit_account: %{id: d.id, name: d.name, gl_code: d.gl_code},
        credit_account: %{id: c.id, name: c.name, gl_code: c.gl_code}
      }
    )
  end

  defp hierarchy(query, nil), do: query

  defp hierarchy(query, pattern),
    do: where(query, [_r, o], like(o.hierarchy, ^pattern))

  defp finish(row, associations) do
    row
    |> Map.put(
      :debit,
      side_data(row, @debit, row.debit_account_id, row.debit_account, associations)
    )
    |> Map.put(
      :credit,
      side_data(row, @credit, row.credit_account_id, row.credit_account, associations)
    )
  end

  # a fixed account is listed as the one allowed account; tags are listed (or, when asked for, the
  # accounts they allow)
  defp side_data(_row, _side, account_id, account, _associations) when not is_nil(account_id),
    do: %{tags: nil, accounts: [account]}

  defp side_data(row, side, _account_id, _account, true),
    do: %{tags: nil, accounts: accounts_by_tag(row.id, side)}

  defp side_data(row, side, _account_id, _account, false),
    do: %{tags: tags(row.id, side), accounts: nil}
end
