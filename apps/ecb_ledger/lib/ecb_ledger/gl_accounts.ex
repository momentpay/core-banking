defmodule ECBLedger.GLAccounts do
  @moduledoc """
  The chart of accounts (`acc_gl_account`), read side, following Fineract's
  `GLAccountReadPlatformServiceImpl`.

  An account has a type (asset, liability, equity, income, expense), a usage (*detail* accounts take
  postings, *header* accounts group others), an optional parent and an optional tag from the code list for
  its type. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBOrg.Codes
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.TenantRepo

  @types [
    {1, "accountType.asset", "ASSET", "AssetAccountTags"},
    {2, "accountType.liability", "LIABILITY", "LiabilityAccountTags"},
    {3, "accountType.equity", "EQUITY", "EquityAccountTags"},
    {4, "accountType.income", "INCOME", "IncomeAccountTags"},
    {5, "accountType.expense", "EXPENSE", "ExpenseAccountTags"}
  ]

  @usages [{1, "accountUsage.detail", "DETAIL"}, {2, "accountUsage.header", "HEADER"}]

  @doc "The account types as `%{id, code, value}` options."
  @spec type_options() :: [map]
  def type_options, do: for({id, code, value, _} <- @types, do: option(id, code, value))

  @doc "The account usages as `%{id, code, value}` options."
  @spec usage_options() :: [map]
  def usage_options, do: for({id, code, value} <- @usages, do: option(id, code, value))

  @doc "One type option by id, or `nil`."
  @spec type_option(integer) :: map | nil
  def type_option(id), do: Enum.find(type_options(), &(&1.id == id))

  @doc "The name of the code list that holds the tags for an account type."
  @spec tag_code_name(integer) :: String.t() | nil
  def tag_code_name(type_id) do
    case List.keyfind(@types, type_id, 0) do
      {_, _, _, name} -> name
      nil -> nil
    end
  end

  @doc "True for a type id Fineract knows."
  @spec valid_type?(term) :: boolean
  def valid_type?(id), do: List.keymember?(@types, id, 0)

  @doc "True for a usage id Fineract knows."
  @spec valid_usage?(term) :: boolean
  def valid_usage?(id), do: List.keymember?(@usages, id, 0)

  @doc """
  Accounts by GL code. Filters: `:type`, `:search` (part of the name or code), `:usage`,
  `:manual_entries_allowed`, `:disabled`. An unknown type or usage is refused as Fineract refuses it
  (including its wrong message code).
  """
  @spec list(keyword) :: [map]
  def list(filters \\ []) do
    check_filters!(filters)

    base()
    |> order_by([gl], asc: fragment("? COLLATE \"C\"", gl.gl_code))
    |> filter(filters)
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc "Enabled header accounts of a type, for choosing a parent."
  @spec header_accounts(integer) :: [map]
  def header_accounts(type), do: list(type: type, usage: 2, disabled: false)

  @doc "One account by id, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([gl], gl.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "Like `get/1` but raises the error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, account} -> account
      {:error, error} -> raise error
    end
  end

  @doc "The stored hierarchy path of an account."
  @spec hierarchy(integer) :: String.t() | nil
  def hierarchy(id),
    do: TenantRepo.one(from gl in "acc_gl_account", where: gl.id == ^id, select: gl.hierarchy)

  @doc "The defaults for a new account of a type (an unknown type gives an asset)."
  @spec new_account(integer | nil) :: map
  def new_account(type) do
    type = if valid_type?(type), do: type, else: 1

    %{
      disabled: false,
      manual_entries_allowed: true,
      type: type_option(type),
      usage: Enum.find(usage_options(), &(&1.id == 1)),
      tag: nil
    }
  end

  @doc "The code values that can tag accounts of each type, as `%{asset: [...], liability: [...], ...}`."
  @spec tag_options() :: %{atom => [map]}
  def tag_options do
    for {_id, _code, value, name} <- @types, into: %{} do
      values =
        case Codes.get_by_name(name) do
          {:ok, code} -> Codes.values(code.id)
          {:error, _} -> []
        end

      {value |> String.downcase() |> String.to_atom(), values}
    end
  end

  @doc "True when journal entries have been posted to the account."
  @spec posted?(integer) :: boolean
  def posted?(id),
    do: TenantRepo.exists?(from(j in "acc_gl_journal_entry", where: j.account_id == ^id))

  @doc "True when a product's accounting is mapped to the account."
  @spec mapped_to_product?(integer) :: boolean
  def mapped_to_product?(id),
    do: TenantRepo.exists?(from(m in "acc_product_mapping", where: m.gl_account_id == ^id))

  @doc "True when the account has sub-accounts."
  @spec children?(integer) :: boolean
  def children?(id),
    do: TenantRepo.exists?(from(gl in "acc_gl_account", where: gl.parent_id == ^id))

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.glaccount.id.invalid",
        "General Ledger account with identifier #{id} does not exist ",
        [id]
      )

  # --- internals ------------------------------------------------------------------------------

  defp option(id, code, value), do: %{id: id, code: code, value: value}

  defp base do
    from gl in "acc_gl_account",
      left_join: cv in "m_code_value",
      on: cv.id == gl.tag_id,
      select: %{
        id: gl.id,
        name: gl.name,
        parent_id: gl.parent_id,
        hierarchy: gl.hierarchy,
        gl_code: gl.gl_code,
        disabled: gl.disabled,
        manual_entries_allowed: gl.manual_journal_entries_allowed,
        type_id: gl.classification_enum,
        usage_id: gl.account_usage,
        description: gl.description,
        tag_id: cv.id,
        tag_name: cv.code_value
      }
  end

  defp finish(row) do
    row
    |> Map.put(:type, type_option(row.type_id))
    |> Map.put(:usage, Enum.find(usage_options(), &(&1.id == row.usage_id)))
    |> Map.put(:name_decorated, decorate(row.hierarchy, row.name))
    |> Map.put(:tag, row.tag_id && %{id: row.tag_id, name: row.tag_name})
  end

  defp decorate(hierarchy, name) do
    dots = hierarchy |> to_string() |> String.graphemes() |> Enum.count(&(&1 == "."))
    String.duplicate(".", min(max((dots - 1) * 4, 0), 40)) <> name
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {:type, v}, q when not is_nil(v) ->
        where(q, [gl], gl.classification_enum == ^v)

      {:usage, v}, q when not is_nil(v) ->
        where(q, [gl], gl.account_usage == ^v)

      {:disabled, v}, q when not is_nil(v) ->
        where(q, [gl], gl.disabled == ^v)

      {:manual_entries_allowed, v}, q when not is_nil(v) ->
        where(q, [gl], gl.manual_journal_entries_allowed == ^v)

      {:search, v}, q when v not in [nil, ""] ->
        search(q, v)

      _other, q ->
        q
    end)
  end

  defp search(query, text) do
    pattern = "%" <> String.replace(text, ~w(% _), "") <> "%"
    where(query, [gl], like(gl.name, ^pattern) or like(gl.gl_code, ^pattern))
  end

  defp check_filters!(filters) do
    type = filters[:type]
    usage = filters[:usage]

    cond do
      type != nil and not valid_type?(type) -> invalid_classification!(type)
      usage != nil and not valid_usage?(usage) -> invalid_classification!(nil)
      true -> :ok
    end
  end

  # Fineract's message names a "usage" here whichever filter was wrong; it is kept as it is.
  defp invalid_classification!(value),
    do:
      raise(DomainRuleViolation,
        code: "error.msg.glaccount.usage.invalid",
        message: "The following COA usage is invalid: #{value || "null"}",
        args: []
      )
end
