defmodule ECBLedger.AccountingRules.Write do
  @moduledoc """
  Creating, changing and deleting accounting rules, following Fineract's
  `AccountingRuleWritePlatformServiceJpaRepositoryImpl`.

  Each side of a rule is either one fixed account or a set of tags, never both and never neither. Changing
  a side to a fixed account drops its tags; giving a side tags drops its fixed account. Giving tags a side
  already has changes nothing, and tags the request leaves out are dropped. Runs inside a command's
  transaction.
  """
  import Ecto.Query

  alias ECBLedger.AccountingRules
  alias ECBLedger.AccountingRules.JavaOrder
  alias ECBLedger.GLAccounts
  alias ECBOrg.{Codes, Offices}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.{Integrity, Params, TenantRepo, Validation}

  @debit AccountingRules.debit()
  @credit AccountingRules.credit()

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the rule `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    request = read(params)
    validate_for_create!(request)

    {:ok, _office} = fetch_office!(request.office_id)

    debit = side!(request, :debit, "accountToDebit", "debitTags")
    credit = side!(request, :credit, "accountToCredit", "creditTags")

    description = params |> Params.command_string("description") |> String.trim()
    id = guard(fn -> insert_rule!(request, debit, credit, description) end)

    insert_tags!(id, @debit, debit)
    insert_tags!(id, @credit, credit)
    Result.new(resource_id: id, office_id: request.office_id)
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes rule `id`. The result lists what changed (no `changes` at all when nothing did)."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    request = read(params)
    validate_for_update!(request)

    both!(request.debit_account_id, request.debit_tags, "accountToDebit", "debitTags")
    both!(request.credit_account_id, request.credit_tags, "accountToCredit", "creditTags")

    rule = AccountingRules.fetch!(id)
    {changes, set} = property_changes(params, rule)

    {changes, set} =
      {changes, set}
      |> account_change(params, rule, @debit, request.debit_account_id)
      |> account_change(params, rule, @credit, request.credit_account_id)
      |> tag_change(rule, @credit, request.credit_tags, request.allow_credits, "creditTags")
      |> tag_change(rule, @debit, request.debit_tags, request.allow_debits, "debitTags")
      |> office_change(params, request.office_id)

    unless set == [] do
      # the last change to a column wins
      set = set |> Enum.reverse() |> Map.new() |> Map.to_list()

      guard(fn ->
        TenantRepo.update_all(from(r in "acc_accounting_rule", where: r.id == ^id), set: set)
      end)
    end

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes rule `id` and its tags. Postings made by it stay (they do not point back at it)."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    AccountingRules.fetch!(id)
    TenantRepo.delete_all(from(t in "acc_rule_tags", where: t.acc_rule_id == ^id))
    TenantRepo.delete_all(from(r in "acc_accounting_rule", where: r.id == ^id))
    Result.new(resource_id: id)
  end

  # --- reading the request --------------------------------------------------------------------

  defp read(params) do
    %{
      office_id: Params.long(params, "officeId"),
      debit_account_id: Params.long(params, "accountToDebit"),
      credit_account_id: Params.long(params, "accountToCredit"),
      name: Params.string(params, "name"),
      description: Params.string(params, "description"),
      debit_tags: tags(params, "debitTags"),
      credit_tags: tags(params, "creditTags"),
      allow_debits: Params.boolean(params, "allowMultipleDebitEntries") == true,
      allow_credits: Params.boolean(params, "allowMultipleCreditEntries") == true
    }
  end

  # the tag ids as text, as Fineract passes them on; `nil` when the key is missing or not a list
  defp tags(params, key) do
    case Params.value(params, key) do
      list when is_list(list) ->
        for tag <- list, tag != nil, do: tag |> to_string() |> String.trim()

      _ ->
        nil
    end
  end

  defp validate_for_create!(request) do
    Validation.new("AccountingRule")
    |> Validation.param("accountToDebit", request.debit_account_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("accountToCredit", request.credit_account_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("officeId", request.office_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("name", request.name)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("description", request.description)
    |> Validation.ignore_if_null()
    |> Validation.max_length(500)
    |> validate_tags("creditTags", request.credit_tags)
    |> validate_tags("debitTags", request.debit_tags)
    |> require_side(
      "accountToCredit",
      request.credit_account_id,
      "creditTags",
      request.credit_tags
    )
    |> require_side("accountToDebit", request.debit_account_id, "debitTags", request.debit_tags)
    |> Validation.raise_if_errors!()
  end

  defp validate_for_update!(request) do
    Validation.new("AccountingRule")
    |> Validation.param("accountToDebit", request.debit_account_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("accountToCredit", request.credit_account_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("officeId", request.office_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("name", request.name)
    |> Validation.ignore_if_null()
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("description", request.description)
    |> Validation.ignore_if_null()
    |> Validation.max_length(500)
    |> validate_tags("creditTags", request.credit_tags)
    |> validate_tags("debitTags", request.debit_tags)
    |> Validation.raise_if_errors!()
  end

  # a list of tags must not be empty, and each tag must be a number above zero
  defp validate_tags(validation, name, tags) do
    validation =
      validation
      |> Validation.param(name, tags)
      |> Validation.ignore_if_null()
      |> Validation.array_not_empty()

    Enum.reduce(tags || [], validation, fn tag, v ->
      v
      |> Validation.param(name, tag_number(tag))
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()
    end)
  end

  defp tag_number(tag) do
    case Integer.parse(tag) do
      {number, ""} -> number
      _ -> nil
    end
  end

  # a side needs a fixed account or tags (the message runs its words together, as Fineract's does)
  defp require_side(validation, _account, nil, _tags_name, tags) when tags != nil, do: validation

  defp require_side(validation, _account, account, _tags_name, _tags) when account != nil,
    do: validation

  defp require_side(validation, account_name, nil, tags_name, nil),
    do:
      Validation.add_error(
        validation,
        "validation.msg.#{account_name}.or.#{tags_name}.required",
        "The parameter #{account_name} or#{tags_name} required",
        "#{account_name},#{tags_name}",
        [account_name, tags_name]
      )

  # --- one side of a new rule -----------------------------------------------------------------

  # `{:account, account}`, `{:tags, tag_ids, allow_multiple}`; both or neither is refused
  defp side!(request, side, account_name, tags_name) do
    {account_id, tags, allow} =
      case side do
        :debit -> {request.debit_account_id, request.debit_tags, request.allow_debits}
        :credit -> {request.credit_account_id, request.credit_tags, request.allow_credits}
      end

    both!(account_id, tags, account_name, tags_name)

    cond do
      account_id != nil ->
        {:account, GLAccounts.fetch!(account_id).id}

      tags != nil ->
        ordered = JavaOrder.order(tags)
        Enum.each(ordered, &Codes.fetch_value!(String.to_integer(&1)))
        {:tags, ordered, allow}
    end
  end

  # both a fixed account and tags, or neither, is a mistake
  defp both!(account_id, tags, account_name, tags_name) do
    if account_id != nil and tags != nil do
      raise DomainRuleViolation,
        code: "error.msg.accounting.rule.#{account_name}.or.#{tags_name}.required",
        message: "#{account_name} or #{tags_name} required",
        args: [account_name, tags_name]
    end
  end

  defp insert_rule!(request, debit, credit, description) do
    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "acc_accounting_rule",
        [
          %{
            name: request.name,
            office_id: request.office_id,
            debit_account_id: account_id(debit),
            credit_account_id: account_id(credit),
            description: description,
            system_defined: false,
            allow_multiple_debits: allow(debit),
            allow_multiple_credits: allow(credit)
          }
        ],
        returning: [:id]
      )

    id
  end

  defp account_id({:account, id}), do: id
  defp account_id(_tags), do: nil

  defp allow({:tags, _tags, allow}), do: allow
  defp allow(_account), do: false

  defp insert_tags!(rule_id, side, {:tags, tags, _allow}),
    do: insert_tag_rows!(rule_id, side, tags)

  defp insert_tags!(_rule_id, _side, _account), do: :ok

  defp insert_tag_rows!(rule_id, side, tags) do
    for tag <- tags do
      TenantRepo.insert_all("acc_rule_tags", [
        %{acc_rule_id: rule_id, tag_id: String.to_integer(tag), acc_type_enum: side}
      ])
    end
  end

  # --- what an update changes -----------------------------------------------------------------

  # name, description and the two "allow several entries" flags; ids are compared with what is stored
  defp property_changes(params, rule) do
    {%{}, []}
    |> long_change(params, "officeId", rule.office_id)
    |> long_change(params, "accountToDebit", rule.debit_account_id)
    |> long_change(params, "accountToCredit", rule.credit_account_id)
    |> text_change(params, "name", rule.name, :name)
    |> text_change(params, "description", rule.description, :description)
    |> flag_change(
      params,
      "allowMultipleCreditEntries",
      rule.allow_multiple_credits,
      rule.credit_account_id,
      :allow_multiple_credits
    )
    |> flag_change(
      params,
      "allowMultipleDebitEntries",
      rule.allow_multiple_debits,
      rule.debit_account_id,
      :allow_multiple_debits
    )
  end

  # the id is only noted here (and acted on once the thing it names has been looked up)
  defp long_change({changes, set}, params, key, existing) do
    value = Params.long(params, key)

    if Params.exists?(params, key) and value != nil and value != (existing || 0),
      do: {Map.put(changes, key, value), set},
      else: {changes, set}
  end

  defp text_change({changes, set}, params, key, existing, column) do
    if Params.changed_string?(params, key, existing) do
      value = Params.command_string(params, key)
      {Map.put(changes, key, value), [{column, value} | set]}
    else
      {changes, set}
    end
  end

  # the flag is only kept on a side that has tags (a fixed account has nothing to allow several of)
  defp flag_change({changes, set}, params, key, existing, fixed_account_id, column) do
    value = Params.boolean(params, key)

    if Params.exists?(params, key) and value != nil and value != existing do
      changes = Map.put(changes, key, value)
      if fixed_account_id == nil, do: {changes, [{column, value} | set]}, else: {changes, set}
    else
      {changes, set}
    end
  end

  # A side given a different fixed account loses its tags.
  defp account_change({changes, set}, _params, rule, side, account_id) do
    key = if side == @debit, do: "accountToDebit", else: "accountToCredit"
    column = if side == @debit, do: :debit_account_id, else: :credit_account_id

    if account_id != nil and Map.has_key?(changes, key) do
      account = GLAccounts.fetch!(account_id)

      TenantRepo.delete_all(
        from(t in "acc_rule_tags", where: t.acc_rule_id == ^rule.id and t.acc_type_enum == ^side)
      )

      {changes, [{column, account.id} | set]}
    else
      {changes, set}
    end
  end

  # A side given tags keeps the ones it has that are asked for, drops the others, adds the new ones, and
  # then has no fixed account. Only the tags added are reported.
  defp tag_change({changes, set}, _rule, _side, nil, _allow, _name), do: {changes, set}
  defp tag_change({changes, set}, _rule, _side, [], _allow, _name), do: {changes, set}

  defp tag_change({changes, set}, rule, side, tags, allow, name) do
    incoming = JavaOrder.order(tags)
    existing = rule.id |> AccountingRules.tag_ids(side) |> Enum.map(&Integer.to_string/1)

    drop = Enum.map(existing -- incoming, &String.to_integer/1)

    unless drop == [] do
      TenantRepo.delete_all(
        from(t in "acc_rule_tags",
          where: t.acc_rule_id == ^rule.id and t.acc_type_enum == ^side and t.tag_id in ^drop
        )
      )
    end

    to_add = incoming |> Enum.reject(&(&1 in existing)) |> JavaOrder.order()

    if to_add == [] do
      {changes, set}
    else
      Enum.each(to_add, &Codes.fetch_value!(String.to_integer(&1)))
      guard(fn -> insert_tag_rows!(rule.id, side, to_add) end)

      column = if side == @debit, do: :debit_account_id, else: :credit_account_id
      allow_column = if side == @debit, do: :allow_multiple_debits, else: :allow_multiple_credits
      set = [{column, nil} | set]
      set = if allow, do: [{allow_column, true} | set], else: set
      {Map.put(changes, name, to_add), set}
    end
  end

  defp office_change({changes, set}, _params, nil), do: {changes, set}

  defp office_change({changes, set}, _params, office_id) do
    if Map.has_key?(changes, "officeId") do
      {:ok, office} = fetch_office!(office_id)
      {changes, [{:office_id, office.id} | set]}
    else
      {changes, set}
    end
  end

  # --- internals ------------------------------------------------------------------------------

  defp fetch_office!(office_id) do
    case Offices.get(office_id) do
      {:ok, office} -> {:ok, office}
      {:error, error} -> raise error
    end
  end

  # A second rule of the same name, or the same tag twice on one side, is a data-integrity error whose
  # text Fineract does not recognise on PostgreSQL either, so it is reported as an unknown one.
  defp guard(fun), do: Integrity.translate(fun, %{}, unknown())

  defp unknown,
    do:
      {"error.msg.accounting.rule.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource Accounting Rule."}
end
