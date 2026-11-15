defmodule ECBCatalog.Taxes do
  @moduledoc """
  Tax components and tax groups (`m_tax_component`, `m_tax_group` and their mappings), read side,
  following Fineract's `TaxReadPlatformServiceImpl`.

  A *component* is a named percentage (VAT 10%) with an optional pair of GL accounts the tax is posted
  between; when its percentage changes the old rate is kept in its history with the dates it applied. A
  *group* collects components, each for a stretch of time, and charges and savings products point at a
  group. A group that a charge, savings product or savings account uses is *linked* and cannot be
  re-dated. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.GLAccounts
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  # --- components -----------------------------------------------------------------------------

  @doc "Every component, by id."
  @spec components() :: [map]
  def components,
    do: component_query() |> order_by([c], c.id) |> TenantRepo.all() |> Enum.map(&component/1)

  @doc "One component, or `{:error, ResourceNotFound}`."
  @spec get_component(integer) :: {:ok, map} | {:error, Exception.t()}
  def get_component(id) do
    case component_query() |> where([c], c.id == ^id) |> TenantRepo.one() do
      nil -> {:error, component_not_found(id)}
      row -> {:ok, component(row)}
    end
  end

  @doc "Like `get_component/1` but raises the error."
  @spec fetch_component!(integer) :: map
  def fetch_component!(id) do
    case get_component(id) do
      {:ok, component} -> component
      {:error, error} -> raise error
    end
  end

  @doc """
  The percentage a component has on `date`: its current one when the date is after its start, otherwise
  the one its history shows for the period that covers the date, otherwise `nil`.
  """
  @spec percentage_on(map, Date.t()) :: Decimal.t() | nil
  def percentage_on(component, date) do
    if Date.compare(date, component.start_date) == :gt do
      component.percentage
    else
      case Enum.find(component.histories, &covers?(&1.start_date, &1.end_date, date)) do
        nil -> nil
        history -> history.percentage
      end
    end
  end

  @doc "The dates a component's percentage started to apply: the current one and each in its history."
  @spec start_dates(map) :: [Date.t()]
  def start_dates(component),
    do: [component.start_date | Enum.map(component.histories, & &1.start_date)]

  @doc """
  True when `date` is after `start` and not after `end_date` (open-ended when `nil`). A period with no
  start, which only a request that names no date for a new association makes, covers every date.
  """
  @spec covers?(Date.t() | nil, Date.t() | nil, Date.t()) :: boolean
  def covers?(start, end_date, date),
    do:
      (is_nil(start) or Date.compare(date, start) == :gt) and
        (is_nil(end_date) or Date.compare(date, end_date) != :gt)

  # --- groups ---------------------------------------------------------------------------------

  @doc "Every group with its associations, by id."
  @spec groups() :: [map]
  def groups do
    mappings = mappings_by_group()

    TenantRepo.all(from(g in "m_tax_group", order_by: g.id, select: %{id: g.id, name: g.name}))
    |> Enum.map(&Map.put(&1, :associations, Map.get(mappings, &1.id, [])))
  end

  @doc "One group with its associations, or `{:error, ResourceNotFound}`."
  @spec get_group(integer) :: {:ok, map} | {:error, Exception.t()}
  def get_group(id) do
    case TenantRepo.one(
           from(g in "m_tax_group", where: g.id == ^id, select: %{id: g.id, name: g.name})
         ) do
      nil -> {:error, group_not_found(id)}
      group -> {:ok, Map.put(group, :associations, mappings_by_group(id) |> Map.get(id, []))}
    end
  end

  @doc "Like `get_group/1` but raises the error."
  @spec fetch_group!(integer) :: map
  def fetch_group!(id) do
    case get_group(id) do
      {:ok, group} -> group
      {:error, error} -> raise error
    end
  end

  @doc """
  True when a charge, a savings product or a savings account uses the group. Savings tables arrive with
  the deposits module; until then they cannot use a group.
  """
  @spec linked?(integer) :: boolean
  def linked?(group_id) do
    Enum.any?(~w(m_charge m_savings_product m_savings_account), fn table ->
      table?(table) and
        TenantRepo.query!("SELECT 1 FROM #{table} WHERE tax_group_id = $1 LIMIT 1", [group_id]).num_rows >
          0
    end)
  end

  # --- internals ------------------------------------------------------------------------------

  defp table?(name),
    do:
      TenantRepo.exists?(
        from(t in "tables",
          prefix: "information_schema",
          where: t.table_name == ^name and t.table_schema == "public"
        )
      )

  defp component_query do
    from(c in "m_tax_component",
      select: %{
        id: c.id,
        name: c.name,
        percentage: c.percentage,
        debit_type: c.debit_account_type_enum,
        debit_account_id: c.debit_account_id,
        credit_type: c.credit_account_type_enum,
        credit_account_id: c.credit_account_id,
        start_date: c.start_date
      }
    )
  end

  defp component(row) do
    row
    |> Map.put(:debit_account, account(row.debit_account_id))
    |> Map.put(:credit_account, account(row.credit_account_id))
    |> Map.put(:histories, histories(row.id))
  end

  defp account(nil), do: nil

  defp account(id) do
    case GLAccounts.get(id) do
      {:ok, account} -> account
      {:error, _} -> nil
    end
  end

  defp histories(component_id),
    do:
      from(h in "m_tax_component_history",
        where: h.tax_component_id == ^component_id,
        order_by: h.id,
        select: %{percentage: h.percentage, start_date: h.start_date, end_date: h.end_date}
      )
      |> TenantRepo.all()

  # the associations of one group (or of every group), each with its component, by mapping id
  defp mappings_by_group(group_id \\ nil) do
    query =
      from(m in "m_tax_group_mappings",
        order_by: m.id,
        select: %{
          id: m.id,
          group_id: m.tax_group_id,
          component_id: m.tax_component_id,
          start_date: m.start_date,
          end_date: m.end_date
        }
      )

    query = if group_id, do: where(query, [m], m.tax_group_id == ^group_id), else: query

    components = Map.new(components(), &{&1.id, &1})

    query
    |> TenantRepo.all()
    |> Enum.map(&Map.put(&1, :component, Map.fetch!(components, &1.component_id)))
    |> Enum.group_by(& &1.group_id)
  end

  @doc false
  def component_not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.tax.component.id.invalid",
        "tax component with identifier #{id} does not exist",
        [id]
      )

  @doc false
  def group_not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.tax.group.id.invalid",
        "tax group with identifier #{id} does not exist",
        [id]
      )

  @doc false
  def mapping_not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.tax.group.id.invalid",
        "Tax group mapping with identifier #{id} does not exist",
        [id]
      )
end
