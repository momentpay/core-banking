defmodule ECBPlatform.Audit do
  @moduledoc """
  The stored commands as the audit trail and the maker-checker inbox show them
  (`m_portfolio_command_source`), following Fineract's `AuditReadPlatformServiceImpl`.

  An *audit entry* is any stored command; a *maker-checker entry* is one still awaiting approval. A user
  sees the commands of offices at or below their own. In the inbox a user who is not a checker for
  everything sees only the commands they hold a `*_CHECKER` permission for. Must run inside a tenant scope.

  The names of clients, groups, loans and savings accounts that Fineract also shows arrive with those
  modules; until then they are left out.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.ResultType
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @default_limit 200
  @awaiting 2

  @processing_results [
    {0, "Invalid"},
    {1, "Processed"},
    {2, "Awaiting Approval"},
    {3, "Rejected"},
    {4, "Under Processing"},
    {5, "Error"}
  ]

  @doc "The processing result names, by id."
  @spec processing_results() :: [{integer, String.t()}]
  def processing_results, do: @processing_results

  @doc """
  Audit entries, newest first. Criteria (all optional): `:action_name`, `:entity_name` (a prefix),
  `:resource_id`, `:maker_id`, `:checker_id`, `:status`, `:office_id`, `:client_id`, `:loan_id`,
  `:maker_from`, `:maker_to` (`DateTime`s). Options: `:limit`, `:offset`, `:order_by`, `:sort_order`
  for paged answers.
  """
  @spec entries(User.t(), keyword, keyword) :: [map]
  def entries(%User{} = user, criteria \\ [], opts \\ []) do
    base(user)
    |> criteria(criteria)
    |> order(opts)
    |> limit(^(opts[:limit] || @default_limit))
    |> offset(^(opts[:offset] || 0))
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc "How many audit entries match, for paged answers."
  @spec count(User.t(), keyword) :: non_neg_integer
  def count(%User{} = user, criteria \\ []) do
    base(user)
    |> criteria(criteria)
    |> exclude(:select)
    |> select([aud], count(aud.id))
    |> TenantRepo.one()
  end

  @doc "The entries awaiting approval that the user may check, by id."
  @spec to_be_checked(User.t(), keyword) :: [map]
  def to_be_checked(%User{} = user, criteria \\ []) do
    base(user)
    |> criteria(Keyword.put(criteria, :status, @awaiting))
    |> limited_checker(user)
    |> order_by([aud], aud.id)
    |> TenantRepo.all()
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&finish/1)
  end

  @doc "One entry with its command text, or `{:error, ResourceNotFound}`."
  @spec get(User.t(), integer) :: {:ok, map} | {:error, Exception.t()}
  def get(%User{} = user, id) do
    case base(user) |> where([aud], aud.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, row |> finish() |> Map.put(:with_json, true)}
    end
  end

  @doc """
  What a search form needs: the users in the caller's branch, the action and entity names that can
  appear, and (for the audit, not the inbox) the processing results. `use` is `:audit` or `:makerchecker`.
  """
  @spec search_template(User.t(), :audit | :makerchecker) :: map
  def search_template(%User{} = user, use) do
    pattern = hierarchy_of(user) <> "%"

    users =
      TenantRepo.all(
        from u in "m_appuser",
          join: o in "m_office",
          on: o.id == u.office_id,
          where: u.is_deleted == false and like(o.hierarchy, ^pattern),
          order_by: [asc: fragment("? COLLATE \"C\"", u.username)],
          select: %{id: u.id, username: u.username}
      )

    permissions = capable_permissions(user, use)

    actions =
      permissions
      |> Enum.map(& &1.action_name)
      |> Enum.uniq()
      |> Enum.sort_by(&{if(&1 in ~w(CREATE DELETE UPDATE), do: &1, else: "ZZZ"), &1})

    entities =
      permissions
      |> Enum.map(
        &{&1.entity_name, if(&1.grouping == "datatable", do: "ZZZ", else: &1.entity_name)}
      )
      |> Enum.uniq()
      |> Enum.sort_by(fn {name, classifier} -> {classifier, name} end)
      |> Enum.map(&elem(&1, 0))

    %{
      users: users,
      action_names: actions,
      entity_names: entities,
      processing_results:
        if(use == :audit, do: for({id, name} <- @processing_results, do: %{id: id, name: name}))
    }
  end

  # --- internals ------------------------------------------------------------------------------

  defp base(user) do
    query =
      from aud in "m_portfolio_command_source",
        left_join: mk in "m_appuser",
        on: mk.id == aud.maker_id,
        left_join: ck in "m_appuser",
        on: ck.id == aud.checker_id,
        left_join: o in "m_office",
        on: o.id == aud.office_id,
        select: %{
          id: aud.id,
          action_name: aud.action_name,
          entity_name: aud.entity_name,
          resource_id: aud.resource_id,
          subresource_id: aud.subresource_id,
          client_id: aud.client_id,
          loan_id: aud.loan_id,
          maker: mk.username,
          made_on: aud.made_on_date_utc,
          made_on_local: aud.made_on_date,
          checker: ck.username,
          checked_on: aud.checked_on_date_utc,
          checked_on_local: aud.checked_on_date,
          status: aud.status,
          command_as_json: aud.command_as_json,
          url: aud.api_get_url,
          office_name: o.name,
          ip: aud.client_ip
        }

    hierarchy = hierarchy_of(user)

    if hierarchy == "." do
      query
    else
      pattern = hierarchy <> "%"

      join(query, :inner, [aud], o2 in "m_office",
        on: o2.id == aud.office_id and like(o2.hierarchy, ^pattern)
      )
    end
  end

  defp criteria(query, criteria) do
    Enum.reduce(criteria, query, fn
      {:action_name, v}, q when not is_nil(v) ->
        where(q, [aud], aud.action_name == ^v)

      {:entity_name, v}, q when not is_nil(v) ->
        where(q, [aud], like(aud.entity_name, ^(v <> "%")))

      {:resource_id, v}, q when not is_nil(v) ->
        where(q, [aud], aud.resource_id == ^v)

      {:maker_id, v}, q when not is_nil(v) ->
        where(q, [aud], aud.maker_id == ^v)

      {:checker_id, v}, q when not is_nil(v) ->
        where(q, [aud], aud.checker_id == ^v)

      {:status, v}, q when not is_nil(v) ->
        where(q, [aud], aud.status == ^v)

      {:office_id, v}, q when not is_nil(v) ->
        where(q, [aud], aud.office_id == ^v)

      {:client_id, v}, q when not is_nil(v) ->
        where(q, [aud], aud.client_id == ^v)

      {:loan_id, v}, q when not is_nil(v) ->
        where(q, [aud], aud.loan_id == ^v)

      {:maker_from, v}, q when not is_nil(v) ->
        where(q, [aud], aud.made_on_date_utc >= ^v)

      {:maker_to, v}, q when not is_nil(v) ->
        where(q, [aud], aud.made_on_date_utc <= ^v)

      _other, q ->
        q
    end)
  end

  @orderable %{
    "id" => :id,
    "actionName" => :action_name,
    "entityName" => :entity_name,
    "resourceId" => :resource_id,
    "maker" => :maker_id,
    "madeOnDate" => :made_on_date
  }

  defp order(query, opts) do
    field = Map.get(@orderable, opts[:order_by], :id)
    direction = if opts[:sort_order] in ["asc", "ASC"], do: :asc, else: :desc
    order_by(query, [aud], [{^direction, field(aud, ^field)}])
  end

  # Someone who is not a checker for everything sees only the commands they may check.
  defp limited_checker(query, user) do
    if User.has_permission?(user, "ALL_FUNCTIONS") or
         User.has_permission?(user, "CHECKER_SUPER_USER") do
      query
    else
      join(query, :inner, [aud], p in "m_permission",
        on:
          fragment("REPLACE(?, '_CHECKER', '')", p.action_name) == aud.action_name and
            p.entity_name == aud.entity_name and like(p.code, "%\\_CHECKER")
      )
      |> join(:inner, [aud, ..., p], rp in "m_role_permission", on: rp.permission_id == p.id)
      |> join(:inner, [aud, ..., rp], ur in "m_appuser_role",
        on: ur.role_id == rp.role_id and ur.appuser_id == ^user.id
      )
    end
  end

  defp capable_permissions(user, use) do
    query =
      from p in "m_permission",
        where: not is_nil(p.action_name) and p.action_name != "READ",
        select: %{action_name: p.action_name, entity_name: p.entity_name, grouping: p.grouping}

    if use == :makerchecker and
         not (User.has_permission?(user, "ALL_FUNCTIONS") or
                User.has_permission?(user, "CHECKER_SUPER_USER")) do
      query
      |> join(:inner, [p], rp in "m_role_permission", on: rp.permission_id == p.id)
      |> join(:inner, [p, rp], ur in "m_appuser_role",
        on: ur.role_id == rp.role_id and ur.appuser_id == ^user.id
      )
      |> where([p], like(p.code, "%\\_CHECKER"))
      |> TenantRepo.all()
    else
      TenantRepo.all(query)
    end
  end

  defp finish(row) do
    row
    |> Map.put(:processing_result, processing_result(row.status))
    |> Map.put(:made_on, row.made_on || to_utc(row.made_on_local))
    |> Map.put(:checked_on, row.checked_on || to_utc(row.checked_on_local))
  end

  defp processing_result(status) do
    case List.keyfind(@processing_results, status, 0) do
      {_, name} -> name
      nil -> ResultType.to_int(:invalid) |> to_string()
    end
  end

  defp to_utc(nil), do: nil
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp hierarchy_of(%User{office_id: nil}), do: "."

  defp hierarchy_of(%User{office_id: office_id}),
    do:
      TenantRepo.one(from o in "m_office", where: o.id == ^office_id, select: o.hierarchy) || "."

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.command.id.invalid",
        "Audit with identifier #{id} does not exist",
        [id]
      )
end
