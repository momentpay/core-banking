defmodule ECBCatalog.Taxes.Write do
  @moduledoc """
  Creating and changing tax components and tax groups, following Fineract's `TaxValidator`,
  `TaxAssembler` and `TaxWritePlatformServiceImpl`.

  Rules worth knowing:

    * A component's percentage is above 0 and at most 100. Changing it keeps the old rate in the history
      with the dates it applied, and the new rate starts on the date given (which has to be in the future)
      or today.
    * A group's components, taken together, never come to more than 100 per cent on any date, and a
      component cannot be in a group twice over the same dates.
    * A group's component dates can only be changed before they start, and not at all once a charge or
      savings product uses the group. A component's association can be ended, never removed.

  Both resources are read from a typed request, so fields Fineract does not list are dropped before
  anything is checked. Runs inside a command's transaction.
  """
  import Ecto.Query

  alias ECBCatalog.Taxes
  alias ECBLedger.GLAccounts
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{InvalidJsonData, UnsupportedParameter}

  @component_fields ~w(name percentage debitAccountType debitAccountId creditAccountType creditAccountId startDate dateFormat locale)
  @component_update ~w(dateFormat locale name percentage startDate)
  @group_fields ~w(name locale taxComponents dateFormat)
  @item_fields ~w(id taxComponentId startDate endDate)
  @item_create ~w(taxComponentId startDate)
  @account_types [1, 2, 3, 4, 5]
  @header 2

  # --- components -----------------------------------------------------------------------------

  @doc "Creates the component `params` describe."
  @spec create_component!(Params.t(), map) :: Result.t()
  def create_component!(%Params{} = params, user) do
    params = Params.typed(params, @component_fields)

    name = Params.string(params, "name")
    percentage = Params.decimal(params, "percentage")
    debit = side(params, "debit")
    credit = side(params, "credit")

    Validation.new("tax.component")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.param("percentage", percentage)
    |> Validation.not_blank()
    |> Validation.positive_amount()
    |> Validation.not_greater_than_max(100)
    |> validate_side("debit", debit, :type_first)
    |> validate_side("credit", credit, :id_first)
    |> Validation.raise_if_errors!()

    debit_account = debit.id && GLAccounts.fetch!(debit.id)
    credit_account = credit.id && GLAccounts.fetch!(credit.id)

    Validation.new("tax.component")
    |> check_account("debitAccountId", debit, debit_account)
    |> check_account("creditAccountId", credit, credit_account)
    |> Validation.raise_if_errors!()

    start = Params.date(params, "startDate") || BusinessDate.current()
    now = now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_tax_component",
        [
          %{
            name: name,
            percentage: percentage,
            debit_account_type_enum: debit.type,
            debit_account_id: debit.id,
            credit_account_type_enum: credit.type,
            credit_account_id: credit.id,
            start_date: start,
            createdby_id: user.id,
            created_date: now,
            lastmodifiedby_id: user.id,
            lastmodified_date: now
          }
        ],
        returning: [:id]
      )

    Result.new(resource_id: id)
  end

  @doc "Changes component `id`: its name, or its percentage (with the date the new one starts)."
  @spec update_component!(integer, Params.t(), map) :: Result.t()
  def update_component!(id, %Params{} = params, user) do
    params = Params.typed(params, @component_fields)
    Params.check_supported!(params, @component_update)

    today = BusinessDate.current()
    validate_component_update!(params, today)

    component = Taxes.fetch_component!(id)
    start = Params.date(params, "startDate")

    Validation.new("tax.component")
    |> Validation.param("startDate", start)
    |> Validation.date_after(component.start_date)
    |> Validation.raise_if_errors!()

    {changes, set, history} = component_changes(params, component, start, today)
    changed = apply_component(component, set, history)
    validate_component_in_groups!(changed)

    unless set == [] do
      TenantRepo.update_all(from(c in "m_tax_component", where: c.id == ^id),
        set: set ++ [lastmodifiedby_id: user.id, lastmodified_date: now()]
      )
    end

    if history, do: insert_history!(id, history, user)
    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  defp validate_component_update!(params, today) do
    validation = Validation.new("tax.component")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank(),
        else: validation

    validation =
      if Params.exists?(params, "percentage"),
        do:
          validation
          |> Validation.param("percentage", Params.decimal(params, "percentage"))
          |> Validation.not_blank()
          |> Validation.positive_amount()
          |> Validation.not_greater_than_max(100),
        else: validation

    validation =
      if Params.exists?(params, "startDate"),
        do:
          validation
          |> Validation.param("startDate", Params.date(params, "startDate"))
          |> Validation.date_after(today),
        else: validation

    Validation.raise_if_errors!(validation)
  end

  # A new percentage ends the old one's run in the history on the day the new one starts.
  defp component_changes(params, component, start, today) do
    {changes, set} =
      if Params.changed_string?(params, "name", component.name) do
        name = Params.command_string(params, "name")
        {%{"name" => name}, [name: name]}
      else
        {%{}, []}
      end

    if Params.changed_decimal?(params, "percentage", component.percentage) do
      percentage = Params.decimal(params, "percentage")
      new_start = start || today

      history = %{
        percentage: component.percentage,
        start_date: component.start_date,
        end_date: new_start
      }

      {
        changes |> Map.put("percentage", percentage) |> Map.put("startDate", new_start),
        set ++ [percentage: percentage, start_date: new_start],
        history
      }
    else
      {changes, set, nil}
    end
  end

  defp apply_component(component, set, history) do
    component = Enum.reduce(set, component, fn {key, value}, acc -> Map.put(acc, key, value) end)
    if history, do: Map.update!(component, :histories, &(&1 ++ [history])), else: component
  end

  defp insert_history!(component_id, history, user) do
    now = now()

    TenantRepo.insert_all("m_tax_component_history", [
      %{
        tax_component_id: component_id,
        percentage: history.percentage,
        start_date: history.start_date,
        end_date: history.end_date,
        createdby_id: user.id,
        created_date: now,
        lastmodifiedby_id: user.id,
        lastmodified_date: now
      }
    ])
  end

  # Raising a component can push a group that uses it past 100 per cent.
  defp validate_component_in_groups!(component) do
    groups =
      for group <- Taxes.groups(),
          Enum.any?(group.associations, &(&1.component_id == component.id)),
          do: swap_component(group.associations, component)

    Validation.new("tax.component")
    |> then(fn validation ->
      Enum.reduce(groups, validation, &total_errors(&2, &1, "group.total.percentage"))
    end)
    |> Validation.raise_if_errors!()
  end

  defp swap_component(associations, component),
    do:
      Enum.map(associations, fn
        %{component_id: id} = association when id == component.id ->
          %{association | component: component}

        association ->
          association
      end)

  # --- one side (debit or credit) of a component ----------------------------------------------

  defp side(params, which),
    do: %{
      type: Params.integer(params, which <> "AccountType"),
      id: Params.long(params, which <> "AccountId")
    }

  defp validate_side(validation, which, %{type: type, id: id}, order) do
    type_key = which <> "AccountType"
    id_key = which <> "AccountId"

    validation =
      validation
      |> Validation.param(type_key, type)
      |> Validation.ignore_if_null()
      |> Validation.one_of(@account_types)
      |> Validation.param(id_key, id)
      |> Validation.greater_than_zero()

    if is_nil(type) and is_nil(id) do
      validation
    else
      case order do
        :type_first -> validation |> require(type_key, type) |> require(id_key, id)
        :id_first -> validation |> require(id_key, id) |> require(type_key, type)
      end
    end
  end

  defp require(validation, key, value),
    do: validation |> Validation.param(key, value) |> Validation.not_blank()

  # the account has to be of the type given and has to take postings
  defp check_account(validation, _key, _side, nil), do: validation

  defp check_account(validation, key, %{type: type, id: id}, account) do
    if account.type_id != type or account.usage_id == @header,
      do:
        validation
        |> Validation.param(key, id)
        |> Validation.fail_with_code("not.a.valid.account"),
      else: validation
  end

  # --- groups ---------------------------------------------------------------------------------

  @doc "Creates the group `params` describe, with its components."
  @spec create_group!(Params.t(), map) :: Result.t()
  def create_group!(%Params{} = params, user) do
    params = typed_group(params)
    items = items(params)

    validate_group_create!(params, items)

    mappings = items |> Enum.map(&assemble(&1, params, false))
    validate_group!(mappings)

    now = now()

    {1, [%{id: group_id}]} =
      TenantRepo.insert_all(
        "m_tax_group",
        [
          %{
            name: Params.string(params, "name"),
            createdby_id: user.id,
            created_date: now,
            lastmodifiedby_id: user.id,
            lastmodified_date: now
          }
        ],
        returning: [:id]
      )

    for mapping <- mappings, do: insert_mapping!(group_id, mapping, user)
    Result.new(resource_id: group_id)
  end

  @doc """
  Changes group `id`: its name, the end of a component's association, or the components it has. Only what
  really changes is reported: `name`, `addComponents` (component ids) and `modifiedComponents`.
  """
  @spec update_group!(integer, Params.t(), map) :: Result.t()
  def update_group!(id, %Params{} = params, user) do
    params = typed_group(params)
    items = items(params)

    validate_group_update!(params, items)

    group = Taxes.fetch_group!(id)
    mappings = Enum.map(items, &assemble(&1, params, true))
    validate_end_dates!(group, mappings, Taxes.linked?(id))

    {changes, final, edits, additions} = group_changes(params, group, mappings)
    validate_group!(final)

    unless changes == %{} do
      if Map.has_key?(changes, "name"),
        do:
          TenantRepo.update_all(from(g in "m_tax_group", where: g.id == ^id),
            set: [name: changes["name"], lastmodifiedby_id: user.id, lastmodified_date: now()]
          )

      for {mapping_id, set} <- edits do
        TenantRepo.update_all(
          from(m in "m_tax_group_mappings", where: m.id == ^mapping_id),
          set: set ++ [lastmodifiedby_id: user.id, lastmodified_date: now()]
        )
      end

      for mapping <- additions, do: insert_mapping!(id, mapping, user)
    end

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  # name, locale, dateFormat and the list of components, each with its four fields
  defp typed_group(params) do
    typed = Params.typed(params, @group_fields)

    case Params.value(typed, "taxComponents") do
      nil ->
        typed

      list when is_list(list) ->
        %Params{map: Map.put(typed.map, "taxComponents", typed_items(list))}

      _other ->
        raise InvalidJsonData
    end
  end

  # the items of the list, each reduced to the fields Fineract reads
  defp typed_items(list) do
    unless Enum.all?(list, &is_map/1), do: raise(InvalidJsonData)

    for item <- list do
      item |> Map.take(@item_fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp items(params), do: Params.value(params, "taxComponents") || []

  defp validate_group_create!(params, items) do
    list = Params.value(params, "taxComponents")

    Validation.new("tax.group")
    |> Validation.param("name", Params.string(params, "name"))
    |> Validation.not_blank()
    |> Validation.param("taxComponents", list)
    |> Validation.not_null()
    |> create_items(list, items)
    |> Validation.raise_if_errors!()
  end

  defp create_items(validation, nil, _items), do: validation

  defp create_items(validation, _list, items) do
    validation =
      if items == [],
        do:
          Validation.add_error(
            validation,
            "validation.msg.at.least.one.tax.component.required",
            "Please add at least one Tax Component before submitting the Tax Group.",
            "taxComponents",
            []
          ),
        else: validation

    validation =
      validation
      |> Validation.param("taxComponents", length(items))
      |> Validation.greater_than_zero()

    items
    |> Enum.with_index(1)
    |> Enum.reduce(validation, fn {item, index}, v ->
      check_item_keys!(item, @item_create)
      component_id(v, Params.long(%Params{map: item}, "taxComponentId"), index)
    end)
  end

  # a component is named by its id, which has to be there and above zero
  defp component_id(validation, nil, index),
    do:
      Validation.add_error(
        validation,
        "validation.msg.tax.group.taxComponents.taxComponentId.cannot.be.blank",
        "The parameter `taxComponents[#{index}][taxComponentId]` is mandatory.",
        "taxComponents[#{index}][taxComponentId]",
        [index]
      )

  defp component_id(validation, id, _index),
    do: validation |> Validation.param("taxComponents", id) |> Validation.greater_than_zero()

  defp check_item_keys!(item, supported) do
    case item |> Map.keys() |> Enum.reject(&(&1 in supported)) do
      [] -> :ok
      unknown -> raise UnsupportedParameter, parameters: Enum.sort(unknown)
    end
  end

  defp validate_group_update!(params, items) do
    today = BusinessDate.current()
    validation = Validation.new("tax.group")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank(),
        else: validation

    validation =
      items
      |> Enum.with_index(1)
      |> Enum.reduce(validation, fn {item, index}, v ->
        update_item(v, params, item, index, today)
      end)

    Validation.raise_if_errors!(validation)
  end

  # a component being added needs its id; one already in the group needs the id of its association
  defp update_item(validation, params, item, index, today) do
    item_params = item_params(item, params)
    mapping_id = Params.long(item_params, "id")
    component = Params.long(item_params, "taxComponentId")
    component_key = "taxComponents.taxComponentId.at.index.#{index}"

    validation =
      if is_nil(mapping_id) do
        validation
        |> Validation.param(component_key, component)
        |> Validation.not_null()
        |> Validation.greater_than_zero()
      else
        validation
        |> Validation.param(component_key, component)
        |> Validation.greater_than_zero()
        |> Validation.param("taxComponents.id.at.index.#{index}", mapping_id)
        |> Validation.greater_than_zero()
      end

    end_date = Params.date(item_params, "endDate")

    validation =
      if is_nil(mapping_id),
        do:
          validation
          |> Validation.param("taxComponents.endDate.at.index.#{index}", end_date)
          |> Validation.ignore_if_null()
          |> Validation.date_after(today),
        else: validation

    start_date = Params.date(item_params, "startDate")

    if end_date && start_date,
      do:
        Validation.add_error(
          validation,
          "validation.msg.tax.group.taxComponents.at.index.#{index}.start.date.end.date.both.should.not.be.present",
          "Failed data validation due to: start.date.end.date.both.should.not.be.present.",
          "taxComponents.at.index.#{index}",
          [nil, [date_array(start_date), date_array(end_date)]]
        ),
      else: validation
  end

  defp date_array(%Date{year: y, month: m, day: d}), do: [y, m, d]

  # an item read with the request's date format and locale
  defp item_params(item, params),
    do: %Params{map: Map.merge(item, Map.take(params.map, ["dateFormat", "locale"]))}

  # An association as the request describes it: the component (which has to exist), and its dates. A new
  # association with no dates starts today; an existing one keeps what it has unless told otherwise.
  defp assemble(item, params, update?) do
    item_params = item_params(item, params)
    mapping_id = Params.long(item_params, "id")
    component_id = Params.long(item_params, "taxComponentId")
    component = component_id && Taxes.fetch_component!(component_id)
    start = Params.date(item_params, "startDate")
    end_date = Params.date(item_params, "endDate")
    existing? = update? and mapping_id != nil

    start =
      if is_nil(end_date) and is_nil(start) and not existing?,
        do: BusinessDate.current(),
        else: start

    %{
      id: if(existing?, do: mapping_id),
      component: component,
      start_date: start,
      end_date: if(existing?, do: end_date)
    }
  end

  # --- the dates of the associations of a group being changed ---------------------------------

  defp validate_end_dates!(group, mappings, linked?) do
    today = BusinessDate.current()

    mappings
    |> Enum.reduce(Validation.new("tax.group"), fn mapping, validation ->
      cond do
        mapping.id != nil ->
          existing = existing!(group, mapping.id)
          existing_mapping(validation, mapping, existing, linked?, today)

        mapping.end_date != nil ->
          validation
          |> Validation.param("endDate", nil)
          |> Validation.fail_with_code("not.supported.for.new.association")

        true ->
          validation
      end
    end)
    |> Validation.raise_if_errors!()
  end

  defp existing!(group, mapping_id) do
    Enum.find(group.associations, &(&1.id == mapping_id)) ||
      raise Taxes.mapping_not_found(mapping_id)
  end

  defp existing_mapping(validation, mapping, existing, linked?, today) do
    {validation, effective_start} = start_change(validation, mapping, existing, linked?, today)
    end_date = mapping.end_date || existing.end_date

    validation =
      if is_nil(mapping.end_date) and end_date != nil and
           Date.compare(effective_start, end_date) != :lt,
         do:
           validation
           |> Validation.param("startDate", effective_start)
           |> Validation.add_error(
             "validation.msg.tax.group.startDate.must.be.before.end.date",
             "Failed data validation due to: must.be.before.end.date.",
             "startDate",
             [Date.to_iso8601(effective_start), [Date.to_iso8601(end_date)]]
           ),
         else:
           validation
           |> Validation.param("endDate", mapping.end_date)
           |> Validation.ignore_if_null()
           |> Validation.date_after(effective_start)

    if mapping.component != nil and mapping.component.id != existing.component_id,
      do:
        validation
        |> Validation.param("taxComponentId", nil)
        |> Validation.fail_with_code("update.not.supported"),
      else: validation
  end

  # a start date can be changed only before it has come, and never while a charge or product uses the group
  defp start_change(validation, mapping, existing, linked?, today) do
    changed? =
      mapping.start_date != nil and Date.compare(mapping.start_date, existing.start_date) != :eq

    cond do
      not changed? ->
        {validation, existing.start_date}

      linked? ->
        {fail(validation, "startDate", "cannot.be.modified.for.linked.tax.group"),
         existing.start_date}

      Date.compare(existing.start_date, today) != :gt ->
        {fail(validation, "startDate", "cannot.be.modified.after.activation"),
         existing.start_date}

      true ->
        {validation
         |> Validation.param("startDate", mapping.start_date)
         |> Validation.date_not_before(today), mapping.start_date}
    end
  end

  defp fail(validation, key, code),
    do: validation |> Validation.param(key, nil) |> Validation.fail_with_code(code)

  # What the update does to the group: the changes to report, the associations it ends up with, the edits
  # to existing ones and the associations to add.
  defp group_changes(params, group, mappings) do
    name_changes =
      if Params.changed_string?(params, "name", group.name),
        do: %{"name" => Params.command_string(params, "name")},
        else: %{}

    {edits, modified, additions, added_ids} = sort_mappings(group, mappings)

    changes =
      name_changes
      |> put_unless_empty("addComponents", added_ids)
      |> put_unless_empty("modifiedComponents", modified)

    {changes, final_state(group, edits, additions), edits, additions}
  end

  # splits the requested associations into edits of existing ones and new ones
  defp sort_mappings(group, mappings) do
    Enum.reduce(mappings, {[], [], [], []}, fn mapping, acc ->
      sort_mapping(group, mapping, acc)
    end)
  end

  defp sort_mapping(_group, %{id: nil} = mapping, {edits, modified, additions, added}),
    do: {edits, modified, additions ++ [mapping], added ++ [mapping.component.id]}

  defp sort_mapping(group, mapping, {edits, modified, additions, added}) do
    {set, notes} = edit(mapping, existing!(group, mapping.id))
    edits = if set == [], do: edits, else: edits ++ [{mapping.id, set}]
    {edits, modified ++ notes, additions, added}
  end

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  # a date that is given and differs from the stored one
  defp edit(mapping, existing) do
    component_id = existing.component_id

    {set, notes} =
      if mapping.start_date != nil and
           Date.compare(mapping.start_date, existing.start_date) != :eq,
         do:
           {[start_date: mapping.start_date],
            [%{"startDate" => mapping.start_date, "taxComponentId" => component_id}]},
         else: {[], []}

    if mapping.end_date != nil and
         (existing.end_date == nil or Date.compare(mapping.end_date, existing.end_date) != :eq),
       do:
         {set ++ [end_date: mapping.end_date],
          notes ++ [%{"endDate" => mapping.end_date, "taxComponentId" => component_id}]},
       else: {set, notes}
  end

  defp final_state(group, edits, additions) do
    edited = Enum.map(group.associations, &apply_edit(&1, List.keyfind(edits, &1.id, 0)))

    edited ++
      for mapping <- additions,
          do: %{
            id: nil,
            component_id: mapping.component.id,
            component: mapping.component,
            start_date: mapping.start_date,
            end_date: nil
          }
  end

  defp apply_edit(association, nil), do: association

  defp apply_edit(association, {_id, set}),
    do: Enum.reduce(set, association, fn {key, value}, acc -> Map.put(acc, key, value) end)

  # --- what has to hold of a group -------------------------------------------------------------

  # `mappings` are `%{component_id | component, start_date, end_date}`: new ones carry the component
  defp validate_group!(mappings) do
    mappings = Enum.map(mappings, &normalise/1)

    Validation.new("tax.group")
    |> total_errors(mappings, "total.percentage")
    |> overlap_errors(mappings)
    |> Validation.raise_if_errors!()
  end

  defp normalise(%{component_id: _} = mapping), do: mapping

  defp normalise(%{component: component} = mapping),
    do: Map.put(mapping, :component_id, component.id)

  # On every date a component's percentage started to apply, the group's components that apply the day
  # after add up to at most 100.
  defp total_errors(validation, mappings, parameter) do
    mappings = Enum.map(mappings, &normalise/1)

    mappings
    |> Enum.flat_map(fn mapping ->
      Enum.map(Taxes.start_dates(mapping.component), &Date.add(&1, 1))
    end)
    |> Enum.uniq()
    |> Enum.map(&total_on(mappings, &1))
    |> Enum.filter(&(Decimal.compare(&1, 100) == :gt))
    |> Enum.uniq()
    |> Enum.reduce(validation, fn total, v ->
      v |> Validation.param(parameter, total) |> Validation.not_greater_than_max(100)
    end)
  end

  defp total_on(mappings, date) do
    mappings
    |> Enum.filter(&Taxes.covers?(&1.start_date, &1.end_date, date))
    |> Enum.map(&Taxes.percentage_on(&1.component, date))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  # the same component twice over the same dates (each pair is looked at both ways round, as in Fineract)
  defp overlap_errors(validation, mappings) do
    indexed = Enum.with_index(mappings)

    pairs =
      for {a, i} <- indexed,
          {b, j} <- indexed,
          i != j,
          a.component_id == b.component_id,
          do: {a, b}

    Enum.reduce(pairs, validation, fn {a, b}, v ->
      cond do
        is_nil(a.end_date) and is_nil(b.end_date) ->
          v
          |> Validation.param("component", nil)
          |> Validation.fail_with_code("dates.are.overlapping")

        Date.compare(a.start_date, b.start_date) == :gt ->
          v
          |> Validation.param("component.start.date", a.start_date)
          |> Validation.date_after(b.end_date)

        true ->
          v
          |> Validation.param("component.start.date", b.start_date)
          |> Validation.date_after(a.end_date)
      end
    end)
  end

  defp insert_mapping!(group_id, mapping, user) do
    now = now()

    TenantRepo.insert_all("m_tax_group_mappings", [
      %{
        tax_group_id: group_id,
        tax_component_id: mapping.component.id,
        start_date: mapping.start_date,
        end_date: nil,
        createdby_id: user.id,
        created_date: now,
        lastmodifiedby_id: user.id,
        lastmodified_date: now
      }
    ])
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
