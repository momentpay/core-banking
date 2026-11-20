defmodule ECBDeposits.InterestCharts do
  @moduledoc """
  The interest rate charts of deposit products (`m_interest_rate_chart`, its slabs and their incentives), after
  Fineract's `InterestRateChart`, `InterestRateChartFields`, `InterestRateChartSlabFields`,
  `InterestRateChartDataValidator`, `InterestRateChartSlabDataValidator` and `InterestRateChartReadServiceImpl`.

  A chart says which annual rate a deposit earns by the length of its term and its amount: its slabs run by
  period (or, when the chart is grouped by amount, by amount first) without gap or overlap, and a slab may carry
  incentives. A product keeps its charts in `m_deposit_product_interest_rate_chart`. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.DepositEnums
  alias ECBPlatform.Errors.ServerError
  alias ECBPlatform.{Json, Params, TenantRepo, Validation}

  @create_params ~w(locale dateFormat name description fromDate endDate productId chartSlabs isPrimaryGroupingByAmount)
  @update_params ~w(locale dateFormat id name description fromDate endDate chartSlabs delete isPrimaryGroupingByAmount)

  # --- reading ---------------------------------------------------------------------------------------

  @doc "The charts of a product with their slabs and incentives, by chart id."
  @spec for_product(integer) :: [map]
  def for_product(product_id) do
    charts =
      from(c in "m_interest_rate_chart",
        join: l in "m_deposit_product_interest_rate_chart",
        on: l.interest_rate_chart_id == c.id,
        where: l.deposit_product_id == ^product_id,
        order_by: c.id,
        select: %{
          id: c.id,
          name: c.name,
          description: c.description,
          from_date: c.from_date,
          end_date: c.end_date,
          grouping: c.is_primary_grouping_by_amount
        }
      )
      |> TenantRepo.all()

    Enum.map(charts, fn chart -> Map.put(chart, :slabs, slabs(chart.id)) end)
  end

  defp slabs(chart_id) do
    from(s in "m_interest_rate_slab",
      where: s.interest_rate_chart_id == ^chart_id,
      order_by: s.id,
      select: %{
        id: s.id,
        description: s.description,
        period_type: s.period_type_enum,
        from_period: s.from_period,
        to_period: s.to_period,
        amount_from: s.amount_range_from,
        amount_to: s.amount_range_to,
        rate: s.annual_interest_rate,
        currency_code: s.currency_code
      }
    )
    |> TenantRepo.all()
    |> Enum.map(fn slab -> Map.put(slab, :incentives, incentives(slab.id)) end)
  end

  defp incentives(slab_id) do
    from(i in "m_interest_incentives",
      left_join: cv in "m_code_value",
      on: fragment("cast(? as char(50))", cv.id) == i.attribute_value,
      where: i.interest_rate_slab_id == ^slab_id,
      order_by: i.id,
      select: %{
        id: i.id,
        entity: i.entiry_type,
        attribute: i.attribute_name,
        condition: i.condition_type,
        value: i.attribute_value,
        value_desc: cv.code_value,
        type: i.incentive_type,
        amount: i.amount
      }
    )
    |> TenantRepo.all()
    |> Enum.map(fn i ->
      if DepositEnums.code_value_attribute?(i.attribute), do: i, else: %{i | value_desc: nil}
    end)
  end

  @doc """
  The chart that counts as the active one of a list: Fineract walks the list keeping the first until a chart
  comes that the kept one starts after the end of.
  """
  @spec active([map]) :: map | nil
  def active([]), do: nil

  def active([first | rest]) do
    Enum.reduce(rest, first, fn chart, kept ->
      if starts_after?(kept, chart.end_date), do: kept, else: chart
    end)
  end

  defp starts_after?(_chart, nil), do: false
  defp starts_after?(chart, date), do: Date.compare(chart.from_date, date) == :gt

  # --- checking a request ---------------------------------------------------------------------------

  @doc """
  Checks the `charts` of a product request (`validateChartsData`): the list is needed and not empty, each chart
  with an `id` is checked as a change to a chart, any other as a new chart.
  """
  @spec validate_request(Validation.t(), Params.t()) :: Validation.t()
  def validate_request(v, %Params{} = p) do
    case Params.value(p, "charts") do
      nil ->
        Validation.scoped(v, &(&1 |> Validation.param("charts", nil) |> Validation.not_null()))

      [] ->
        Validation.scoped(v, fn v ->
          v
          |> Validation.param("charts", [])
          |> Validation.not_null()
          |> Validation.array_not_empty()
        end)

      list when is_list(list) ->
        v =
          Validation.scoped(v, &(&1 |> Validation.param("charts", list) |> Validation.not_null()))

        Enum.reduce(list, v, fn chart, acc -> validate_chart(acc, chart) end)

      _other ->
        raise ServerError
    end
  end

  # a chart is read from its text again, which leaves out what it says is null
  defp validate_chart(v, %{} = chart) do
    chart = strip_nulls(chart)
    p = %Params{map: chart, order: Map.keys(chart)}

    if Map.has_key?(chart, "id"), do: validate_update(v, p), else: validate_create(v, p)
  end

  defp validate_chart(_v, _other), do: raise(ServerError)

  defp strip_nulls(%{} = map),
    do:
      map
      |> Enum.reject(fn {_k, value} -> is_nil(value) end)
      |> Map.new(fn {k, x} -> {k, strip_nulls(x)} end)

  defp strip_nulls(list) when is_list(list), do: Enum.map(list, &strip_nulls/1)
  defp strip_nulls(other), do: other

  defp validate_create(v, p) do
    Params.check_supported!(p, @create_params)

    v = v |> named(p) |> described(p)
    {v, from} = checked_date(v, p, "fromDate")
    {v, to} = optional_date(v, p, "endDate")

    v
    |> from_after_to(from, to)
    |> slabs_given(Params.value(p, "chartSlabs"))
    |> validate_slabs_request(p, grouping?(p))
  end

  defp validate_update(v, p) do
    Params.check_supported!(p, @update_params)

    v = if Params.exists?(p, "productId"), do: product_id(v, p), else: v
    v = v |> named(p) |> described(p)
    {v, from} = optional_date(v, p, "fromDate")
    {v, to} = optional_date(v, p, "endDate")

    v
    |> from_after_to(from, to)
    |> validate_slabs_request(p, grouping?(p))
  end

  defp scoped(v, fun), do: Validation.scoped(v, fun)

  defp grouping?(p), do: Params.boolean(p, "isPrimaryGroupingByAmount") == true

  defp product_id(v, p) do
    scoped(v, fn v ->
      v
      |> Validation.param("productId", Json.long(p, "productId"))
      |> Validation.not_null()
      |> Validation.greater_than_zero()
    end)
  end

  defp checked_date(v, p, key) do
    date = Params.date(p, key)
    {scoped(v, &(&1 |> Validation.param(key, date) |> Validation.not_null())), date}
  end

  defp optional_date(v, p, key),
    do: if(Params.exists?(p, key), do: checked_date(v, p, key), else: {v, nil})

  # a chart of slabs: the slabs are needed and there must be one
  defp slabs_given(v, slabs) do
    scoped(v, fn v ->
      v = v |> Validation.param("chartSlabs", slabs) |> Validation.not_null()
      if slabs == [], do: Validation.array_not_empty(v), else: v
    end)
  end

  defp named(v, p) do
    if Params.exists?(p, "name"),
      do:
        scoped(
          v,
          &(&1 |> Validation.param("name", Params.string(p, "name")) |> Validation.not_blank())
        ),
      else: v
  end

  defp described(v, p) do
    if Params.exists?(p, "description"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("description", Params.string(p, "description"))
            |> Validation.not_null())
        ),
      else: v
  end

  # not in a scope of its own: what it names stays for the problems recorded after it
  defp from_after_to(v, %Date{} = from, %Date{} = to) do
    if Date.compare(from, to) == :gt,
      do:
        v
        |> Validation.param("fromDate", from)
        |> Validation.fail_with_code("from.date.is.after.to.date"),
      else: v
  end

  defp from_after_to(v, _from, _to), do: v

  defp validate_slabs_request(v, p, grouping) do
    case Params.value(p, "chartSlabs") do
      list when is_list(list) ->
        locale = Params.locale(p)
        Enum.reduce(list, v, &validate_one_slab(&2, slab_params(&1, locale), grouping))

      _ ->
        v
    end
  end

  defp validate_one_slab(v, slab, grouping) do
    if Params.exists?(slab, "id"),
      do: v |> checked_id(slab) |> validate_slab_update(slab, grouping),
      else: validate_slab_create(v, slab, grouping)
  end

  defp checked_id(v, p) do
    scoped(v, fn v ->
      v
      |> Validation.param("id", Json.long(p, "id"))
      |> Validation.not_null()
      |> Validation.greater_than_zero()
    end)
  end

  defp slab_params(%{} = slab, locale),
    do: %Params{map: if(locale, do: Map.put(slab, "locale", locale), else: slab)}

  defp slab_params(_other, _locale), do: raise(ServerError)

  # --- a new slab ---------------------------------------------------------------------------------

  defp validate_slab_create(v, s, grouping) do
    period_type = Params.integer_with_locale(s, "periodType")
    from_period = Params.integer_with_locale(s, "fromPeriod")

    v
    |> slab_description(s, &Validation.not_null/1)
    |> create_period_type(s, period_type)
    |> create_from_period(s, from_period)
    |> period_required(period_type, from_period, grouping)
    |> create_periods(s, from_period)
    |> create_amounts(s, grouping, from_period)
    |> create_rate(s)
    |> validate_incentives(s)
  end

  defp slab_description(v, s, check) do
    if Params.exists?(s, "description"),
      do:
        scoped(
          v,
          &(&1 |> Validation.param("description", Params.string(s, "description")) |> check.())
        ),
      else: v
  end

  defp create_period_type(v, s, period_type) do
    if Params.exists?(s, "periodType"),
      do:
        scoped(v, fn v ->
          v
          |> Validation.param("periodType", period_type)
          |> Validation.one_of(DepositEnums.chart_period_ids())
        end),
      else: v
  end

  defp create_from_period(v, s, from_period) do
    if Params.exists?(s, "fromPeriod"),
      do:
        scoped(
          v,
          &(&1 |> Validation.param("fromPeriod", from_period) |> Validation.zero_or_greater())
        ),
      else: v
  end

  # a chart grouped by period (or a slab that names a period) needs its type and its start
  defp period_required(v, period_type, from_period, grouping) do
    if not grouping or period_type != nil or from_period != nil do
      v
      |> scoped(&(&1 |> Validation.param("periodType", period_type) |> Validation.not_null()))
      |> scoped(&(&1 |> Validation.param("fromPeriod", from_period) |> Validation.not_null()))
    else
      v
    end
  end

  defp create_periods(v, s, from_period) do
    {v, to_period} = to_period(v, s)
    from_after_to_period(v, from_period, to_period, "fromperiod.greater.than.to.period")
  end

  defp create_amounts(v, s, grouping, from_period) do
    amount_from = Params.decimal_with_locale(s, "amountRangeFrom")
    amount_to = Params.decimal_with_locale(s, "amountRangeTo")

    v
    |> amount_from_checks(s, amount_from, grouping)
    |> amount_to_checks(s, amount_to)
    |> either_given(amount_from, from_period)
    |> amounts_in_order(amount_from, amount_to)
  end

  defp amount_from_checks(v, s, amount_from, grouping) do
    if Params.exists?(s, "amountRangeFrom") do
      v =
        scoped(
          v,
          &(&1
            |> Validation.param("amountRangeFrom", amount_from)
            |> Validation.zero_or_positive_amount())
        )

      if grouping,
        do:
          scoped(
            v,
            &(&1 |> Validation.param("amountRangeFrom", amount_from) |> Validation.not_null())
          ),
        else: v
    else
      v
    end
  end

  defp amount_to_checks(v, s, amount_to) do
    if Params.exists?(s, "amountRangeTo"),
      do:
        scoped(
          v,
          &(&1 |> Validation.param("amountRangeTo", amount_to) |> Validation.positive_amount())
        ),
      else: v
  end

  defp either_given(v, nil, nil),
    do: Validation.fail_without_parameter(v, "fromperiod.or.amountRangeFrom.required")

  defp either_given(v, _amount_from, _from_period), do: v

  defp amounts_in_order(v, %Decimal{} = from, %Decimal{} = to) do
    if Decimal.gt?(from, to),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("amountRangeFrom", from)
            |> Validation.fail_with_code("from.amount.greater.than.to.amount"))
        ),
      else: v
  end

  defp amounts_in_order(v, _from, _to), do: v

  defp create_rate(v, s) do
    rate = Params.decimal_with_locale(s, "annualInterestRate")

    scoped(
      v,
      &(&1
        |> Validation.param("annualInterestRate", rate)
        |> Validation.not_null()
        |> Validation.zero_or_positive_amount())
    )
  end

  defp to_period(v, s) do
    if Params.exists?(s, "toPeriod") do
      to = Params.integer_with_locale(s, "toPeriod")
      {scoped(v, &(&1 |> Validation.param("toPeriod", to) |> Validation.greater_than_zero())), to}
    else
      {v, nil}
    end
  end

  # not in a scope of its own: what it names stays for the problems recorded after it
  defp from_after_to_period(v, from, to, code)
       when is_integer(from) and is_integer(to) and from > to,
       do: v |> Validation.param("fromPeriod", from) |> Validation.fail_with_code(code)

  defp from_after_to_period(v, _from, _to, _code), do: v

  # --- a slab that is changed --------------------------------------------------------------------------

  defp validate_slab_update(v, s, grouping) do
    from_period =
      if Params.exists?(s, "fromPeriod"), do: Params.integer_with_locale(s, "fromPeriod")

    v
    |> slab_description(s, &Validation.ignore_if_null/1)
    |> update_period_type(s, grouping)
    |> update_from_period(s, from_period, grouping)
    |> update_periods(s, from_period)
    |> update_amounts(s, grouping, from_period)
    |> update_rate(s)
    |> update_currency(s)
    |> validate_incentives(s)
  end

  defp update_period_type(v, s, grouping) do
    if Params.exists?(s, "periodType"),
      do: period_type_changed(v, Params.integer_with_locale(s, "periodType"), grouping),
      else: v
  end

  defp period_type_changed(v, type, grouping) do
    scoped(v, fn v ->
      v =
        v
        |> Validation.param("periodType", type)
        |> Validation.one_of(DepositEnums.chart_period_ids())

      if grouping, do: v, else: v |> Validation.param("periodType", type) |> Validation.not_null()
    end)
  end

  defp update_from_period(v, s, from, grouping) do
    if Params.exists?(s, "fromPeriod"), do: from_period_changed(v, from, grouping), else: v
  end

  defp from_period_changed(v, from, grouping) do
    scoped(v, fn v ->
      v = v |> Validation.param("fromPeriod", from) |> Validation.zero_or_greater()
      if grouping, do: v, else: v |> Validation.param("fromPeriod", from) |> Validation.not_null()
    end)
  end

  defp update_periods(v, s, from_period) do
    {v, to_period} = to_period(v, s)
    from_after_to_period(v, from_period, to_period, "fromperiod.greater.than.toperiod")
  end

  defp update_amounts(v, s, grouping, from_period) do
    amount_from =
      if Params.exists?(s, "amountRangeFrom"),
        do: Params.decimal_with_locale(s, "amountRangeFrom")

    amount_to =
      if Params.exists?(s, "amountRangeTo"), do: Params.decimal_with_locale(s, "amountRangeTo")

    v
    |> update_amount_from(s, amount_from, grouping)
    |> update_amount_to(s, amount_to)
    |> amounts_misordered(amount_from, amount_to, from_period)
  end

  defp update_amount_from(v, s, amount_from, grouping) do
    if Params.exists?(s, "amountRangeFrom"),
      do: amount_from_changed(v, amount_from, grouping),
      else: v
  end

  defp amount_from_changed(v, amount_from, grouping) do
    scoped(v, fn v ->
      v =
        v
        |> Validation.param("amountRangeFrom", amount_from)
        |> Validation.zero_or_positive_amount()

      if grouping,
        do: v |> Validation.param("amountRangeFrom", amount_from) |> Validation.not_null(),
        else: v
    end)
  end

  defp update_amount_to(v, s, amount_to) do
    if Params.exists?(s, "amountRangeTo"),
      do:
        scoped(
          v,
          &(&1 |> Validation.param("amountRangeTo", amount_to) |> Validation.positive_amount())
        ),
      else: v
  end

  # Fineract names the period here, not the amount
  defp amounts_misordered(v, %Decimal{} = from, %Decimal{} = to, from_period) do
    if Decimal.gt?(from, to),
      do:
        v
        |> Validation.param("fromPeriod", from_period)
        |> Validation.fail_with_code("fromperiod.greater.than.toperiod"),
      else: v
  end

  defp amounts_misordered(v, _from, _to, _from_period), do: v

  defp update_rate(v, s) do
    if Params.exists?(s, "annualInterestRate") do
      rate = Params.decimal_with_locale(s, "annualInterestRate")

      scoped(
        v,
        &(&1
          |> Validation.param("annualInterestRate", rate)
          |> Validation.not_null()
          |> Validation.zero_or_positive_amount())
      )
    else
      v
    end
  end

  defp update_currency(v, s) do
    if Params.exists?(s, "currencyCode") do
      scoped(v, fn v ->
        v
        |> Validation.param("currencyCode", Params.string(s, "currencyCode"))
        |> Validation.not_blank()
        |> Validation.max_length(3)
      end)
    else
      v
    end
  end

  # --- incentives --------------------------------------------------------------------------------------

  defp validate_incentives(v, s) do
    case Params.value(s, "incentives") do
      list when is_list(list) -> Enum.reduce(list, v, &validate_incentive(&2, &1, s))
      _ -> v
    end
  end

  defp validate_incentive(v, item, s) do
    i = %Params{map: Map.put(extract_map(item), "locale", Params.locale(s))}

    if Params.exists?(i, "id"),
      do: v |> checked_id(i) |> incentive_update(i),
      else: incentive_create(v, i)
  end

  defp extract_map(%{} = map), do: map
  defp extract_map(_other), do: raise(ServerError)

  defp incentive_create(v, i) do
    v
    |> enum_param(i, "entityType", DepositEnums.incentive_entity_ids())
    |> enum_param(i, "attributeName", DepositEnums.incentive_attribute_ids())
    |> enum_param(i, "conditionType", DepositEnums.incentive_condition_ids())
    |> scoped(
      &(&1
        |> Validation.param("attributeValue", Params.string(i, "attributeValue"))
        |> Validation.not_null())
    )
    |> enum_param(i, "incentiveType", DepositEnums.incentive_type_ids())
    |> scoped(
      &(&1
        |> Validation.param("amount", Params.decimal_with_locale(i, "amount"))
        |> Validation.not_null())
    )
  end

  defp enum_param(v, i, key, ids) do
    scoped(v, fn v ->
      v
      |> Validation.param(key, Params.integer_with_locale(i, key))
      |> Validation.not_null()
      |> Validation.one_of(ids)
    end)
  end

  defp enum_param_if_given(v, i, key, ids),
    do: if(Params.exists?(i, key), do: enum_param(v, i, key, ids), else: v)

  defp incentive_update(v, i) do
    v
    |> slab_description(i, &Validation.not_null/1)
    |> enum_param_if_given(i, "entityType", DepositEnums.incentive_entity_ids())
    |> enum_param_if_given(i, "attributeName", DepositEnums.incentive_attribute_ids())
    |> enum_param_if_given(i, "conditionType", DepositEnums.incentive_condition_ids())
    |> incentive_value(i)
    |> enum_param_if_given(i, "incentiveType", DepositEnums.incentive_type_ids())
    |> incentive_amount(i)
  end

  defp incentive_value(v, i) do
    if Params.exists?(i, "attributeValue"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("attributeValue", Params.string(i, "attributeValue"))
            |> Validation.not_null())
        ),
      else: v
  end

  defp incentive_amount(v, i) do
    if Params.exists?(i, "amount"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("amount", Params.decimal_with_locale(i, "amount"))
            |> Validation.not_null())
        ),
      else: v
  end

  # --- the rules of a whole chart ---------------------------------------------------------------------

  @doc """
  The platform rules of a chart's slabs (`InterestRateChart.validateChartSlabs`): each slab has what its kind of
  chart is grouped by, the first starts where it should, all have one kind of period, and neighbours leave no gap
  and do not overlap. `chart` carries `grouping` and `slabs` (`from_period`, `to_period`, `amount_from`,
  `amount_to`, `period_type`).
  """
  @spec validate_slabs(Validation.t(), map) :: Validation.t()
  def validate_slabs(v, %{grouping: grouping, slabs: slabs}) do
    sorted = sort(slabs, grouping)
    state = %{period?: not grouping, amount?: grouping, type: nil}
    count = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.reduce({v, state}, fn {slab, i}, {acc, st} ->
      {acc, st} = check_slab(acc, st, slab, i, grouping)
      next = if i + 1 < count, do: Enum.at(sorted, i + 1)
      {check_pair(acc, slab, next, grouping), st}
    end)
    |> elem(0)
  end

  defp check_slab(v, st, slab, i, grouping) do
    v = if valid?(slab, grouping), do: v, else: blank_slab(v, grouping)
    check_kinds(v, st, slab, i, valid?(slab, grouping))
  end

  defp blank_slab(v, true),
    do:
      v
      |> Validation.param("amountRangeFrom", nil)
      |> Validation.fail_with_code("cannot.be.blank")

  defp blank_slab(v, false),
    do: v |> Validation.param("fromPeriod", nil) |> Validation.fail_with_code("cannot.be.blank")

  # a slab that has what the chart is grouped by is checked against the first
  defp check_kinds(v, st, slab, i, true) when i > 0 do
    {v, st} =
      if st.period? != (slab.from_period != nil) do
        {Validation.fail_without_parameter(v, "chart.slabs.period.range.incomplete"),
         %{st | period?: st.period? or slab.from_period != nil}}
      else
        {v, st}
      end

    {v, st} =
      if st.amount? != (slab.amount_from != nil) do
        {Validation.fail_without_parameter(v, "chart.slabs.amount.range.incomplete"),
         %{st | amount?: st.amount? or slab.amount_from != nil}}
      else
        {v, st}
      end

    same_type(v, st, slab)
  end

  defp check_kinds(v, st, slab, 0, _valid?), do: first_slab(v, st, slab)
  defp check_kinds(v, st, slab, _i, _valid?), do: same_type(v, st, slab)

  defp first_slab(v, st, slab) do
    v =
      if not_proper_start?(slab),
        do:
          Validation.fail_without_parameter(v, "chart.slabs.range.start.incorrect", [
            slab.from_period,
            slab.amount_from
          ]),
        else: v

    {v,
     %{
       st
       | type: slab.period_type,
         amount?: st.amount? or slab.amount_from != nil,
         period?: st.period? or slab.from_period != nil
     }}
  end

  defp same_type(v, st, %{period_type: type} = slab)
       when type != nil and type != st.type and slab != nil do
    v =
      v
      |> Validation.param("periodType", type)
      |> Validation.fail_with_code("period.type.is.not.same", [st.type])

    {v, st}
  end

  defp same_type(v, st, _slab), do: {v, st}

  defp check_pair(v, _slab, nil, _grouping), do: v

  defp check_pair(v, slab, next, grouping) do
    if valid?(slab, grouping) and valid?(next, grouping) do
      v |> overlap_or_gap(slab, next, grouping) |> after_neighbour(slab, next, grouping)
    else
      v
    end
  end

  defp overlap_or_gap(v, slab, next, grouping) do
    args = [
      slab.from_period,
      slab.to_period,
      next.from_period,
      next.to_period,
      slab.amount_from,
      slab.amount_to,
      next.amount_from,
      next.amount_to
    ]

    cond do
      overlapping?(slab, next, grouping) -> slab_problem(v, "overlap", args)
      gap?(slab, next, grouping) -> slab_problem(v, "gap", args)
      true -> v
    end
  end

  # Fineract writes these under a resource of their own
  defp slab_problem(v, code, args) do
    sub = %{Validation.new("savings.interestRateChart") | errors: v.errors}
    sub = sub |> Validation.param("slabs", nil) |> Validation.fail_with_code(code, args)
    %{v | errors: sub.errors}
  end

  defp after_neighbour(v, slab, next, true) do
    if amount_same?(slab, next) do
      v
    else
      v =
        if not_proper_period_start?(next),
          do:
            Validation.fail_without_parameter(v, "chart.slabs.period.range.start.incorrect", [
              next.to_period
            ]),
          else: v

      if slab.to_period != nil,
        do:
          Validation.fail_without_parameter(v, "chart.slabs.period.range.end.incorrect", [
            slab.to_period
          ]),
        else: v
    end
  end

  defp after_neighbour(v, slab, next, false) do
    if periods_same?(slab, next) do
      v
    else
      v =
        if not_proper_amount_start?(next.amount_from),
          do:
            Validation.fail_without_parameter(v, "chart.slabs.amount.range.start.incorrect", [
              next.amount_from
            ]),
          else: v

      if slab.amount_to != nil,
        do:
          Validation.fail_without_parameter(v, "chart.slabs.amount.range.end.incorrect", [
            slab.amount_to
          ]),
        else: v
    end
  end

  defp valid?(slab, false), do: slab.from_period != nil
  defp valid?(slab, true), do: slab.amount_from != nil

  defp not_proper_start?(slab),
    do: not_proper_period_start?(slab) or not_proper_amount_start?(slab.amount_from)

  # a first slab starts at 0 or 1 (a slab without a period is not wrong)
  defp not_proper_period_start?(%{from_period: nil}), do: false
  defp not_proper_period_start?(%{from_period: from}), do: from not in [0, 1]

  defp not_proper_amount_start?(nil), do: false

  defp not_proper_amount_start?(amount),
    do: not (Decimal.eq?(amount, 1) or Decimal.eq?(amount, 0))

  # --- ordering, overlap and gap ------------------------------------------------------------------------

  defp sort(slabs, grouping), do: Enum.sort(slabs, fn a, b -> compare(a, b, grouping) <= 0 end)

  defp compare(a, b, grouping) do
    cond do
      periods_same?(a, b) and amount_same?(a, b) -> 0
      grouping and amount_same?(a, b) -> compare_periods(a, b)
      grouping -> compare_amounts(a, b)
      periods_same?(a, b) -> compare_amounts(a, b)
      true -> compare_periods(a, b)
    end
  end

  defp compare_periods(%{from_period: x}, %{from_period: y}) when x != nil and y != nil,
    do: cmp(x, y)

  defp compare_periods(_a, _b), do: 0

  defp compare_amounts(%{amount_from: x}, %{amount_from: y}) when x != nil and y != nil,
    do: Decimal.compare(x, y) |> decimal_order()

  defp compare_amounts(_a, _b), do: 0

  defp cmp(x, y) when x < y, do: -1
  defp cmp(x, y) when x > y, do: 1
  defp cmp(_x, _y), do: 0

  defp decimal_order(:lt), do: -1
  defp decimal_order(:gt), do: 1
  defp decimal_order(:eq), do: 0

  defp periods_same?(a, b), do: a.from_period == b.from_period and a.to_period == b.to_period

  defp amount_same?(a, b),
    do: dec_same?(a.amount_from, b.amount_from) and dec_same?(a.amount_to, b.amount_to)

  defp dec_same?(nil, nil), do: true
  defp dec_same?(nil, _), do: false
  defp dec_same?(_, nil), do: false
  defp dec_same?(a, b), do: Decimal.eq?(a, b)

  defp overlapping?(a, b, grouping) do
    period = period_overlap?(a, b)
    amount = amount_overlap?(a, b)

    if grouping,
      do: (amount and not amount_same?(a, b)) or (period and amount_same?(a, b)),
      else: (period and not periods_same?(a, b)) or (amount and periods_same?(a, b))
  end

  # `this` is `a`, `that` is `b`
  defp period_overlap?(a, b) do
    cond do
      b.to_period == a.to_period -> true
      b.from_period == a.from_period -> true
      a.to_period == nil -> true
      b.to_period == nil -> b.from_period <= a.to_period
      true -> a.from_period <= b.to_period and b.from_period <= a.to_period
    end
  end

  defp amount_overlap?(a, b) do
    cond do
      dec_same?(b.amount_from, a.amount_from) ->
        true

      dec_same?(b.amount_to, a.amount_to) ->
        true

      a.amount_to == nil ->
        true

      b.amount_to == nil ->
        Decimal.lte?(b.amount_from, a.amount_to)

      true ->
        Decimal.lte?(a.amount_from, b.amount_to) and Decimal.lte?(b.amount_from, a.amount_to)
    end
  end

  defp gap?(a, b, true), do: gap_by_amount(a, b)
  defp gap?(a, b, false), do: gap_by_period(a, b)

  # grouped by amount: slabs of one range follow by period, a new range follows the last
  defp gap_by_amount(a, b) do
    if amount_same?(a, b),
      do: either_period?(a, b) and improper_period_start?(a, b.from_period),
      else: improper_amount_start?(a, b.amount_from) or not_proper_period_start?(b)
  end

  # grouped by period: slabs of one period follow by amount, a new period follows the last
  defp gap_by_period(a, b) do
    if periods_same?(a, b),
      do: either_amount?(a, b) and improper_amount_start?(a, b.amount_from),
      else: improper_period_start?(a, b.from_period) or not_proper_amount_start?(b.amount_from)
  end

  defp either_period?(a, b), do: a.from_period != nil or b.from_period != nil
  defp either_amount?(a, b), do: a.amount_from != nil or b.amount_from != nil

  defp improper_period_start?(a, period),
    do: a.to_period == nil or (period != nil and period != a.to_period + 1)

  defp improper_amount_start?(a, amount),
    do:
      a.amount_to == nil or
        (amount != nil and not Decimal.eq?(amount, Decimal.add(a.amount_to, 1)))

  @doc "Whether two charts' dates overlap (an open end counts as the business date)."
  @spec dates_overlap?(map, map, Date.t()) :: boolean
  def dates_overlap?(a, b, today) do
    a_end = a.end_date || today
    b_end = b.end_date || today

    interval_touches?(a.from_date, a_end, b.from_date, b_end) or
      interval_touches?(b.from_date, b_end, a.from_date, a_end)
  end

  # `containsPortionOf`: the other interval starts or ends within this one
  defp interval_touches?(from, to, other_from, other_to) do
    within?(from, to, other_from) or within?(from, to, other_to)
  end

  defp within?(from, to, date),
    do: Date.compare(date, from) != :lt and Date.compare(date, to) != :gt

  @doc """
  The problems of charts that overlap in dates (`chart.overlapping.from.and.end.dates`), one for each ordered pair
  of different charts, with the dates of the first and then the second.
  """
  @spec validate_dates(Validation.t(), [map], Date.t()) :: Validation.t()
  def validate_dates(v, charts, today) do
    for a <- charts, b <- charts, a != b, dates_overlap?(a, b, today), reduce: v do
      acc ->
        Validation.fail_without_parameter(acc, "chart.overlapping.from.and.end.dates", [
          dates(a.from_date),
          dates(a.end_date),
          dates(b.from_date),
          dates(b.end_date)
        ])
    end
  end

  defp dates(nil), do: nil
  defp dates(%Date{} = date), do: [date.year, date.month, date.day]

  # --- storing --------------------------------------------------------------------------------------------

  @doc "Makes a chart from a request's chart (`map`) for `product_id`: the chart, its slabs and their incentives."
  @spec create!(integer, map, String.t(), integer) :: integer
  def create!(product_id, chart, currency_code, user_id) do
    p = chart_params(chart)

    {1, [%{id: chart_id}]} =
      TenantRepo.insert_all(
        "m_interest_rate_chart",
        [
          %{
            name: Params.string(p, "name"),
            description: Params.string(p, "description"),
            from_date: Params.date(p, "fromDate"),
            end_date: Params.date(p, "endDate"),
            is_primary_grouping_by_amount: Params.boolean(p, "isPrimaryGroupingByAmount") == true
          }
        ],
        returning: [:id]
      )

    for slab <- slab_list(chart), do: add_slab!(chart_id, slab, Params.locale(p), currency_code)
    link!(product_id, chart_id)
    _ = user_id
    chart_id
  end

  defp link!(product_id, chart_id) do
    TenantRepo.insert_all("m_deposit_product_interest_rate_chart", [
      %{deposit_product_id: product_id, interest_rate_chart_id: chart_id}
    ])
  end

  @doc "A request's chart as a chart for the rules: `grouping` and the `slabs` as they would be stored."
  @spec assemble(map) :: map
  def assemble(chart) do
    p = chart_params(chart)
    locale = Params.locale(p)

    %{
      name: Params.string(p, "name"),
      description: Params.string(p, "description"),
      from_date: Params.date(p, "fromDate"),
      end_date: Params.date(p, "endDate"),
      grouping: Params.boolean(p, "isPrimaryGroupingByAmount") == true,
      slabs: Enum.map(slab_list(chart), &slab_attrs(&1, locale))
    }
  end

  defp chart_params(chart), do: %Params{map: chart, order: Map.keys(chart)}

  defp slab_list(chart) do
    case Map.get(chart, "chartSlabs") do
      list when is_list(list) -> Enum.map(list, &extract_map/1)
      _ -> []
    end
  end

  @doc "The values of a request's slab."
  @spec slab_attrs(map, String.t() | nil) :: map
  def slab_attrs(slab, locale) do
    s = slab_params(slab, locale)
    type = Params.integer_with_locale(s, "periodType")

    %{
      description: Params.string(s, "description"),
      period_type: if(type in [0, 1, 2, 3], do: type),
      from_period: Params.integer_with_locale(s, "fromPeriod"),
      to_period: Params.integer_with_locale(s, "toPeriod"),
      amount_from: Params.decimal_with_locale(s, "amountRangeFrom"),
      amount_to: Params.decimal_with_locale(s, "amountRangeTo"),
      rate: Params.decimal_with_locale(s, "annualInterestRate")
    }
  end

  @doc "Adds a slab (with its incentives) to a chart."
  @spec add_slab!(integer, map, String.t() | nil, String.t() | nil) :: :ok
  def add_slab!(chart_id, slab, locale, currency_code) do
    attrs = slab_attrs(slab, locale)

    {1, [%{id: slab_id}]} =
      TenantRepo.insert_all(
        "m_interest_rate_slab",
        [
          %{
            interest_rate_chart_id: chart_id,
            description: attrs.description,
            period_type_enum: attrs.period_type,
            from_period: attrs.from_period,
            to_period: attrs.to_period,
            amount_range_from: attrs.amount_from,
            amount_range_to: attrs.amount_to,
            annual_interest_rate: attrs.rate,
            currency_code: currency_code
          }
        ],
        returning: [:id]
      )

    add_incentives!(slab_id, slab, locale)
  end

  defp add_incentives!(slab_id, slab, locale) do
    case Map.get(slab, "incentives") do
      list when is_list(list) ->
        for item <- list,
            not Map.has_key?(extract_map(item), "id"),
            do: add_incentive!(slab_id, item, locale)

        :ok

      _ ->
        :ok
    end
  end

  @doc "Adds an incentive to a slab."
  @spec add_incentive!(integer, map, String.t() | nil) :: :ok
  def add_incentive!(slab_id, item, locale) do
    i = %Params{map: item |> extract_map() |> put_locale(locale)}

    TenantRepo.insert_all("m_interest_incentives", [
      %{
        interest_rate_slab_id: slab_id,
        entiry_type: Params.integer_with_locale(i, "entityType"),
        attribute_name: Params.integer_with_locale(i, "attributeName"),
        condition_type: Params.integer_with_locale(i, "conditionType"),
        attribute_value: Params.string(i, "attributeValue"),
        incentive_type: Params.integer_with_locale(i, "incentiveType"),
        amount: Params.decimal_with_locale(i, "amount")
      }
    ])

    :ok
  end

  defp put_locale(map, nil), do: map
  defp put_locale(map, locale), do: Map.put(map, "locale", locale)

  @doc "Removes the charts of a product, with their slabs and incentives."
  @spec delete_all!(integer) :: :ok
  def delete_all!(product_id) do
    ids =
      from(l in "m_deposit_product_interest_rate_chart",
        where: l.deposit_product_id == ^product_id,
        select: l.interest_rate_chart_id
      )
      |> TenantRepo.all()

    TenantRepo.delete_all(
      from(l in "m_deposit_product_interest_rate_chart",
        where: l.deposit_product_id == ^product_id
      )
    )

    Enum.each(ids, &delete_chart!/1)
  end

  @doc "Removes one chart (its slabs and incentives too) that is not linked any more."
  @spec delete_chart!(integer) :: :ok
  def delete_chart!(chart_id) do
    slab_ids =
      from(s in "m_interest_rate_slab",
        where: s.interest_rate_chart_id == ^chart_id,
        select: s.id
      )
      |> TenantRepo.all()

    TenantRepo.delete_all(
      from(i in "m_interest_incentives", where: i.interest_rate_slab_id in ^slab_ids)
    )

    TenantRepo.delete_all(
      from(s in "m_interest_rate_slab", where: s.interest_rate_chart_id == ^chart_id)
    )

    TenantRepo.delete_all(from(c in "m_interest_rate_chart", where: c.id == ^chart_id))
    :ok
  end
end
