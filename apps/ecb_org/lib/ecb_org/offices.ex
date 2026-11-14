defmodule ECBOrg.Offices do
  @moduledoc """
  Offices (`m_office`): the hierarchy of branches and head office that scopes users, clients and
  accounts.

  Follows Fineract's `OfficeReadPlatformServiceImpl`:

    * A user sees only the offices at or below their own in the hierarchy (`hierarchy LIKE '<theirs>%'`),
      unless `include_all` is given.
    * An office has a `hierarchy` path such as `.` (head office) or `.1.4.` (a branch under office 1).
    * `name_decorated` indents a child's name with 4 dots per level below the head office.

  Every function must run inside a tenant scope. Results are plain maps with atom keys; dates are
  `Date`. Checking that the user may read offices (`READ_OFFICE`) is the caller's job.
  """
  import Ecto.Query

  alias ECBOrg.Errors.{InvalidOrdering, OfficeNotFound}
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @type office :: %{
          id: integer,
          name: String.t(),
          name_decorated: String.t(),
          external_id: String.t() | nil,
          opening_date: Date.t() | nil,
          hierarchy: String.t(),
          parent_id: integer | nil,
          parent_name: String.t() | nil
        }

  # The names Fineract accepts for `orderBy` (the column aliases of its query).
  @order_fields ~w(id name nameDecorated externalId openingDate hierarchy)

  @doc """
  The offices the user can see, as a list.

  ## Options

    * `:include_all` - every office, not just the user's branch of the tree (default false)
    * `:order_by` - one of `id`, `name`, `nameDecorated`, `externalId`, `openingDate`,
      `hierarchy` (default: `hierarchy`); anything else, including the parent columns, is refused as Fineract does
    * `:sort_order` - `asc` or `desc`, used with `:order_by`
  """
  @spec list(User.t(), keyword) :: {:ok, [office]} | {:error, Exception.t()}
  def list(%User{} = user, opts \\ []) do
    with {:ok, order} <- order_clause(opts[:order_by], opts[:sort_order]) do
      pattern = if opts[:include_all], do: ".%", else: user_hierarchy(user) <> "%"

      offices =
        from(o in "m_office",
          left_join: p in "m_office",
          on: p.id == o.parent_id,
          where: like(o.hierarchy, ^pattern),
          order_by: ^order,
          select: %{
            id: o.id,
            name: o.name,
            external_id: o.external_id,
            opening_date: o.opening_date,
            hierarchy: o.hierarchy,
            parent_id: p.id,
            parent_name: p.name
          }
        )
        |> TenantRepo.all()
        |> Enum.map(&decorate/1)

      {:ok, offices}
    end
  end

  @doc "One office by id, or `{:error, OfficeNotFound}`. Not limited to the user's branch, as in Fineract."
  @spec get(integer) :: {:ok, office} | {:error, Exception.t()}
  def get(office_id) when is_integer(office_id) do
    office =
      from(o in "m_office",
        left_join: p in "m_office",
        on: p.id == o.parent_id,
        where: o.id == ^office_id,
        select: %{
          id: o.id,
          name: o.name,
          external_id: o.external_id,
          opening_date: o.opening_date,
          hierarchy: o.hierarchy,
          parent_id: p.id,
          parent_name: p.name
        }
      )
      |> TenantRepo.one()

    if office, do: {:ok, decorate(office)}, else: {:error, %OfficeNotFound{office_id: office_id}}
  end

  @doc """
  What a client needs to fill in a new-office form: today's date as the default opening date and the
  offices that may be a parent (the user's branch of the tree).
  """
  @spec template(User.t()) :: %{opening_date: Date.t(), allowed_parents: [map]}
  def template(%User{} = user) do
    parents =
      TenantRepo.all(
        from o in "m_office",
          where: like(o.hierarchy, ^(user_hierarchy(user) <> "%")),
          order_by: o.hierarchy,
          select: %{id: o.id, name: o.name, hierarchy: o.hierarchy}
      )
      |> Enum.map(fn o ->
        %{id: o.id, name: o.name, name_decorated: name_decorated(o.hierarchy, o.name)}
      end)

    %{opening_date: Date.utc_today(), allowed_parents: parents}
  end

  @doc """
  The name with 4 dots per level below the head office: `.1.2.` is two levels down, so 4 dots. At most
  40 dots, as in Fineract's SQL.
  """
  @spec name_decorated(String.t(), String.t()) :: String.t()
  def name_decorated(hierarchy, name) do
    levels = hierarchy |> String.graphemes() |> Enum.count(&(&1 == ".")) |> Kernel.-(1)
    String.duplicate(".", min(max(levels * 4, 0), 40)) <> name
  end

  # --- internals ------------------------------------------------------------------------------

  defp decorate(office),
    do: Map.put(office, :name_decorated, name_decorated(office.hierarchy, office.name))

  # The hierarchy of the user's own office; the head office's "." when the user has none.
  defp user_hierarchy(%User{office_id: nil}), do: "."

  defp user_hierarchy(%User{office_id: office_id}) do
    TenantRepo.one(from o in "m_office", where: o.id == ^office_id, select: o.hierarchy) || "."
  end

  defp order_clause(nil, nil), do: {:ok, [asc: dynamic([o, p], o.hierarchy)]}
  defp order_clause(nil, _sort_order), do: {:ok, [asc: dynamic([o, p], o.hierarchy)]}

  defp order_clause(field, sort_order) do
    with :ok <- check_field(field),
         {:ok, direction} <- direction(sort_order) do
      {:ok, [{direction, order_expression(field)}]}
    end
  end

  defp check_field(field) when field in @order_fields, do: :ok

  defp check_field(_field),
    do:
      {:error,
       %InvalidOrdering{
         detail:
           "invalid input for profile 'office-order-by': does not match any permitted pattern"
       }}

  defp direction(nil), do: {:ok, :asc}

  defp direction(value) do
    case String.downcase(value) do
      "asc" -> {:ok, :asc}
      "desc" -> {:ok, :desc}
      _ -> {:error, %InvalidOrdering{detail: "invalid sortOrder value '#{value}'"}}
    end
  end

  defp order_expression("id"), do: dynamic([o, p], o.id)
  defp order_expression("name"), do: dynamic([o, p], o.name)
  defp order_expression("nameDecorated"), do: dynamic([o, p], o.name)
  defp order_expression("externalId"), do: dynamic([o, p], o.external_id)
  defp order_expression("openingDate"), do: dynamic([o, p], o.opening_date)
  defp order_expression("hierarchy"), do: dynamic([o, p], o.hierarchy)
end
