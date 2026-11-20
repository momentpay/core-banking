defmodule ECBDeposits.DepositProducts.ChartChanges do
  @moduledoc """
  What a request to change a deposit product does to its interest rate charts, after Fineract's
  `FixedDepositProduct.updateCharts`, `InterestRateChart.update`, `InterestRateChartFields.update`,
  `InterestRateChartSlab.update` and `InterestIncentivesFields.update`. The charts are changed in memory first, so
  that their rules can be asked of the whole product; what is to be written is answered as a list of operations
  that `run!/1` carries out once the rules hold.

  A chart without an `id` would be added by Fineract through an assembler that is never set up, which ends in an
  unhandled error; here too.
  """
  import Ecto.Query

  alias ECBDeposits.InterestCharts
  alias ECBPlatform.{BusinessDate, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Errors.ServerError

  # --- the charts ------------------------------------------------------------------------------------

  @doc """
  Applies the `charts` of a request to those of product `id`. Answers what is shown as changed, the operations to
  run and the problems of `v` with those of the charts added.
  """
  @spec change(integer, Params.t(), Validation.t()) :: {map, [tuple], Validation.t()}
  def change(id, %Params{} = p, %Validation{} = v) do
    case Params.value(p, "charts") do
      list when is_list(list) ->
        start = %{
          v: v,
          charts: InterestCharts.for_product(id),
          changes: %{},
          deleted: %{},
          ops: []
        }

        done = Enum.reduce(list, start, &change_chart(&2, &1))
        {shown(done), Enum.reverse(done.ops), done.v}

      _ ->
        {%{}, [], v}
    end
  end

  defp shown(state) do
    shown = if state.changes == %{}, do: %{}, else: %{"chartSlabs" => state.changes}
    if state.deleted == %{}, do: shown, else: Map.put(shown, "deletedChartSlabs", state.deleted)
  end

  defp change_chart(_state, element) when not is_map(element), do: raise(ServerError)

  defp change_chart(state, element) do
    cp = %Params{map: element, order: Map.keys(element)}
    if not Params.exists?(cp, "id"), do: raise(ServerError)
    chart_id = Json.long(cp, "id")

    case Enum.find(state.charts, &(&1.id == chart_id)) do
      nil -> %{state | v: missing(state.v, "no.chart.associated.with.id", chart_id)}
      chart -> chart_found(state, chart, cp)
    end
  end

  defp missing(v, code, id),
    do: v |> Validation.param("id", id) |> Validation.fail_with_code(code)

  defp chart_found(state, chart, cp) do
    if Params.exists?(cp, "delete"),
      do: drop_chart(state, chart),
      else: update_chart(state, chart, cp)
  end

  defp drop_chart(state, chart) do
    %{
      state
      | charts: Enum.reject(state.charts, &(&1.id == chart.id)),
        deleted: Map.put(state.deleted, "id", chart.id),
        ops: [{:delete_chart, chart.id} | state.ops]
    }
  end

  defp update_chart(state, chart, cp) do
    locale = Params.locale(cp)
    {state, chart} = chart_fields(state, chart, cp)

    {state, chart} =
      if Params.exists?(cp, "chartSlabs"),
        do: chart_slabs(state, chart, cp, locale),
        else: {state, chart}

    charts = Enum.map(state.charts, fn c -> if c.id == chart.id, do: chart, else: c end)
    %{state | charts: charts, v: overlaps(state.v, charts, chart)}
  end

  # the problems of charts whose dates overlap this one's
  defp overlaps(v, charts, chart) do
    today = BusinessDate.current()

    charts
    |> Enum.filter(&(&1.id != chart.id and InterestCharts.dates_overlap?(chart, &1, today)))
    |> Enum.reduce(v, fn existing, acc ->
      Validation.fail_without_parameter(acc, "chart.overlapping.from.and.end.dates", [
        dates(existing.from_date),
        dates(existing.end_date),
        dates(chart.from_date),
        dates(chart.end_date)
      ])
    end)
  end

  defp dates(nil), do: nil
  defp dates(%Date{} = d), do: [d.year, d.month, d.day]

  # --- the fields of a chart ---------------------------------------------------------------------------

  defp chart_fields(state, chart, cp) do
    changes = field_changes(cp, chart)
    changed = Enum.reduce(changes, chart, &Map.put(&2, &1.field, &1.value))
    shown = Enum.reduce(changes, state.changes, &Map.merge(&2, &1.shown))
    columns = Enum.map(changes, &{&1.column, &1.value})
    ops = if columns == [], do: state.ops, else: [{:update_chart, chart.id, columns} | state.ops]

    v =
      if dates_misordered?(changed),
        do:
          state.v
          |> Validation.param("fromDate", changed.from_date)
          |> Validation.fail_with_code("from.date.is.after.to.date"),
        else: state.v

    {%{state | changes: shown, ops: ops, v: v}, changed}
  end

  defp dates_misordered?(%{from_date: %Date{} = from, end_date: %Date{} = to}),
    do: Date.compare(from, to) == :gt

  defp dates_misordered?(_chart), do: false

  defp field_changes(cp, chart) do
    []
    |> text_change(cp, "name", :name, chart.name)
    |> text_change(cp, "description", :description, chart.description)
    |> date_change(cp, "fromDate", :from_date, chart.from_date)
    |> date_change(cp, "endDate", :end_date, chart.end_date)
    |> grouping_change(cp, chart.grouping)
    |> Enum.reverse()
  end

  defp text_change(list, cp, key, field, existing) do
    if Params.changed_string?(cp, key, existing) do
      value = Params.command_string(cp, key)
      [%{field: field, column: field, value: value, shown: %{key => value}} | list]
    else
      list
    end
  end

  # a date is shown as it was written, with the format and the locale it was written in
  defp date_change(list, cp, key, field, existing) do
    date = if Params.exists?(cp, key), do: Params.date(cp, key)

    if Params.exists?(cp, key) and date != existing do
      shown = %{
        key => Params.string(cp, key),
        "dateFormat" => Params.date_format(cp),
        "locale" => Params.locale(cp)
      }

      [%{field: field, column: field, value: date, shown: shown} | list]
    else
      list
    end
  end

  defp grouping_change(list, cp, existing) do
    new = Params.boolean(cp, "isPrimaryGroupingByAmount") == true

    if Params.exists?(cp, "isPrimaryGroupingByAmount") and new != existing do
      [
        %{
          field: :grouping,
          column: :is_primary_grouping_by_amount,
          value: new,
          shown: %{"isPrimaryGroupingByAmount" => new}
        }
        | list
      ]
    else
      list
    end
  end

  # --- the slabs of a chart ---------------------------------------------------------------------------

  defp chart_slabs(state, chart, cp, locale) do
    slabs = Params.value(cp, "chartSlabs")
    if not is_list(slabs), do: raise(ServerError)

    acc = %{state: state, chart: chart, changes: %{}, deleted: %{}}
    acc = Enum.reduce(slabs, acc, &change_slab(&2, &1, locale))
    state = %{acc.state | changes: add_slab_changes(acc.state.changes, acc.changes, acc.deleted)}
    {%{state | v: InterestCharts.validate_slabs(state.v, acc.chart)}, acc.chart}
  end

  defp add_slab_changes(changes, slab_changes, deleted) do
    changes =
      if slab_changes == %{}, do: changes, else: Map.put(changes, "chartSlabs", slab_changes)

    if deleted == %{}, do: changes, else: Map.put(changes, "deletedChartSlabs", deleted)
  end

  defp change_slab(_acc, element, _locale) when not is_map(element), do: raise(ServerError)

  defp change_slab(acc, element, locale) do
    sp = %Params{map: put_locale(element, locale), order: Map.keys(element)}

    if Params.exists?(sp, "id"),
      do: existing_slab(acc, sp, locale),
      else: new_slab(acc, element, sp, locale)
  end

  defp put_locale(map, nil), do: map
  defp put_locale(map, locale), do: Map.put(map, "locale", locale)

  defp existing_slab(acc, sp, locale) do
    slab_id = Json.long(sp, "id")

    case Enum.find(acc.chart.slabs, &(&1.id == slab_id)) do
      nil ->
        put_in(acc.state.v, missing(acc.state.v, "no.chart.slab.associated.with.id", slab_id))

      slab ->
        slab_found(acc, slab, sp, locale)
    end
  end

  defp slab_found(acc, slab, sp, locale) do
    if Params.exists?(sp, "delete"),
      do: drop_slab(acc, slab),
      else: update_slab(acc, slab, sp, locale)
  end

  defp drop_slab(acc, slab) do
    chart = %{acc.chart | slabs: Enum.reject(acc.chart.slabs, &(&1.id == slab.id))}
    state = %{acc.state | ops: [{:delete_slab, slab.id} | acc.state.ops]}
    %{acc | state: state, chart: chart, deleted: Map.put(acc.deleted, "id", slab.id)}
  end

  defp new_slab(acc, element, sp, locale) do
    attrs = InterestCharts.slab_attrs(element, locale)
    slab = Map.merge(attrs, %{id: nil, currency_code: nil, incentives: []})
    v = slab_order_problems(acc.state.v, slab, sp, "from.period.is.greater.than.to.period")
    chart = %{acc.chart | slabs: acc.chart.slabs ++ [slab]}
    state = %{acc.state | v: v, ops: [{:insert_slab, chart.id, element, locale} | acc.state.ops]}
    %{acc | state: state, chart: chart}
  end

  defp update_slab(acc, slab, sp, locale) do
    {slab2, slab_changes, columns} = slab_fields(slab, sp)
    v = slab_order_problems(acc.state.v, slab2, sp, "from.period.is.greater.than.to.period")
    {v, slab3, incentive_changes, incentive_ops} = update_incentives(v, slab2, sp, locale)

    ops = incentive_ops ++ slab_ops(slab.id, columns) ++ acc.state.ops

    chart = %{
      acc.chart
      | slabs: Enum.map(acc.chart.slabs, fn s -> if s.id == slab.id, do: slab3, else: s end)
    }

    %{
      acc
      | state: %{acc.state | v: v, ops: ops},
        chart: chart,
        changes: acc.changes |> Map.merge(slab_changes) |> Map.merge(incentive_changes)
    }
  end

  defp slab_ops(_id, []), do: []
  defp slab_ops(id, columns), do: [{:update_slab, id, columns}]

  # a slab starting after it ends, or an amount range the wrong way round
  defp slab_order_problems(v, slab, sp, code) do
    v
    |> period_order(slab, sp, code)
    |> amount_order(slab, sp)
  end

  defp period_order(v, %{from_period: from, to_period: to}, sp, code)
       when is_integer(from) and is_integer(to) and from > to,
       do:
         v
         |> Validation.param("fromPeriod", Params.integer_with_locale(sp, "fromPeriod"))
         |> Validation.fail_with_code(code)

  defp period_order(v, _slab, _sp, _code), do: v

  defp amount_order(v, %{amount_from: %Decimal{} = from, amount_to: %Decimal{} = to}, sp) do
    if Decimal.gt?(from, to),
      do:
        v
        |> Validation.param("amountRangeFrom", Params.decimal_with_locale(sp, "amountRangeFrom"))
        |> Validation.fail_with_code("amount.range.from.is.greater.than.amount.range.to"),
      else: v
  end

  defp amount_order(v, _slab, _sp), do: v

  @slab_specs [
    {"description", :description, :description, :string},
    {"periodType", :period_type, :period_type_enum, :integer},
    {"fromPeriod", :from_period, :from_period, :integer},
    {"toPeriod", :to_period, :to_period, :integer},
    {"amountRangeFrom", :amount_from, :amount_range_from, :decimal},
    {"amountRangeTo", :amount_to, :amount_range_to, :decimal},
    {"annualInterestRate", :rate, :annual_interest_rate, :decimal}
  ]

  defp slab_fields(slab, sp), do: apply_specs(@slab_specs, slab, sp)

  @incentive_specs [
    {"entityType", :entity, :entiry_type, :integer},
    {"attributeName", :attribute, :attribute_name, :integer},
    {"conditionType", :condition, :condition_type, :integer},
    {"attributeValue", :value, :attribute_value, :string},
    {"incentiveType", :type, :incentive_type, :integer},
    {"amount", :amount, :amount, :decimal}
  ]

  # answers the record changed, the changes to show and the columns to write
  defp apply_specs(specs, record, params) do
    Enum.reduce(specs, {record, %{}, []}, fn {key, field, column, kind},
                                             {rec, changes, columns} ->
      case read_changed(params, key, Map.fetch!(rec, field), kind) do
        :same ->
          {rec, changes, columns}

        {:changed, new} ->
          {Map.put(rec, field, new), Map.put(changes, key, new), [{column, new} | columns]}
      end
    end)
  end

  defp read_changed(p, key, existing, :string),
    do:
      if(Params.changed_string?(p, key, existing),
        do: {:changed, Params.command_string(p, key)},
        else: :same
      )

  defp read_changed(p, key, existing, kind) do
    if Params.exists?(p, key) do
      new =
        if kind == :integer,
          do: Params.integer_with_locale(p, key),
          else: Params.decimal_with_locale(p, key)

      if differs?(existing, new), do: {:changed, new}, else: :same
    else
      :same
    end
  end

  defp differs?(nil, nil), do: false
  defp differs?(nil, _), do: true
  defp differs?(_, nil), do: true
  defp differs?(%Decimal{} = a, %Decimal{} = b), do: not Decimal.eq?(a, b)
  defp differs?(a, b), do: a != b

  # --- the incentives of a slab ------------------------------------------------------------------------

  # answers the problems, the slab, the changes to show and the operations (latest first)
  defp update_incentives(v, slab, sp, locale) do
    case Params.value(sp, "incentives") do
      list when is_list(list) ->
        start = %{v: v, slab: slab, changes: %{}, deleted: %{}, ops: []}
        done = Enum.reduce(list, start, &change_incentive(&2, &1, locale))
        {done.v, done.slab, incentive_changes(done), done.ops}

      _ ->
        {v, slab, %{}, []}
    end
  end

  defp incentive_changes(done) do
    shown = if done.changes == %{}, do: %{}, else: %{"incentives" => done.changes}
    if done.deleted == %{}, do: shown, else: Map.put(shown, "deletedIncentives", done.deleted)
  end

  defp change_incentive(_acc, element, _locale) when not is_map(element), do: raise(ServerError)

  defp change_incentive(acc, element, locale) do
    ip = %Params{map: put_locale(element, locale), order: Map.keys(element)}

    if Params.exists?(ip, "id"),
      do: existing_incentive(acc, ip),
      else: %{acc | ops: [{:insert_incentive, acc.slab.id, element, locale} | acc.ops]}
  end

  defp existing_incentive(acc, ip) do
    id = Json.long(ip, "id")

    case Enum.find(acc.slab.incentives, &(&1.id == id)) do
      nil -> %{acc | v: missing(acc.v, "no.interest.incentive.associated.with.id", id)}
      incentive -> incentive_found(acc, incentive, ip)
    end
  end

  defp incentive_found(acc, incentive, ip) do
    if Params.exists?(ip, "delete"),
      do: drop_incentive(acc, incentive),
      else: change_incentive_fields(acc, incentive, ip)
  end

  defp drop_incentive(acc, incentive) do
    slab = %{acc.slab | incentives: Enum.reject(acc.slab.incentives, &(&1.id == incentive.id))}

    %{
      acc
      | slab: slab,
        deleted: Map.put(acc.deleted, "id", incentive.id),
        ops: [{:delete_incentive, incentive.id} | acc.ops]
    }
  end

  defp change_incentive_fields(acc, incentive, ip) do
    {changed, changes, columns} = apply_specs(@incentive_specs, incentive, ip)
    incentives = Enum.map(acc.slab.incentives, &if(&1.id == incentive.id, do: changed, else: &1))

    ops =
      if columns == [], do: acc.ops, else: [{:update_incentive, incentive.id, columns} | acc.ops]

    %{
      acc
      | slab: %{acc.slab | incentives: incentives},
        changes: Map.merge(acc.changes, changes),
        ops: ops
    }
  end

  # --- carrying out what was decided -------------------------------------------------------------------

  @doc "Writes one operation of `change/3`."
  @spec run!(tuple) :: term
  def run!({:delete_chart, chart_id}) do
    TenantRepo.delete_all(
      from(l in "m_deposit_product_interest_rate_chart",
        where: l.interest_rate_chart_id == ^chart_id
      )
    )

    InterestCharts.delete_chart!(chart_id)
  end

  def run!({:update_chart, chart_id, columns}),
    do:
      TenantRepo.update_all(from(c in "m_interest_rate_chart", where: c.id == ^chart_id),
        set: columns
      )

  def run!({:update_slab, slab_id, columns}),
    do:
      TenantRepo.update_all(from(s in "m_interest_rate_slab", where: s.id == ^slab_id),
        set: columns
      )

  def run!({:delete_slab, slab_id}) do
    TenantRepo.delete_all(
      from(i in "m_interest_incentives", where: i.interest_rate_slab_id == ^slab_id)
    )

    TenantRepo.delete_all(from(s in "m_interest_rate_slab", where: s.id == ^slab_id))
  end

  def run!({:insert_slab, chart_id, element, locale}) do
    currency =
      TenantRepo.one(
        from(s in "m_interest_rate_slab",
          where: s.interest_rate_chart_id == ^chart_id,
          limit: 1,
          select: s.currency_code
        )
      )

    InterestCharts.add_slab!(chart_id, element, locale, currency)
  end

  def run!({:update_incentive, id, columns}),
    do:
      TenantRepo.update_all(from(i in "m_interest_incentives", where: i.id == ^id), set: columns)

  def run!({:delete_incentive, id}),
    do: TenantRepo.delete_all(from(i in "m_interest_incentives", where: i.id == ^id))

  def run!({:insert_incentive, slab_id, element, locale}),
    do: InterestCharts.add_incentive!(slab_id, element, locale)
end
