defmodule ECBCatalog.FloatingRates do
  @moduledoc """
  Floating interest rates (`m_floating_rates` and their periods), following Fineract's
  `FloatingRatesReadServiceImpl`, `FloatingRateWriteServiceImpl` and the validators of the request.

  A floating rate is a named series of interest rates, each starting on a future date. One floating rate
  can be the *base lending rate*; the others can state their rates as a differential on it. A rate
  replaces its periods by a new series: the old periods that have not started are switched off, the others
  stay. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.{BusinessDate, Integrity, Params, TenantRepo}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{InvalidJsonData, PlatformApiDataValidation, ResourceNotFound}
  alias ECBPlatform.Params.DatePattern

  @fields ~w(name isBaseLendingRate isActive ratePeriods)
  @period_fields ~w(fromDate interestRate isDifferentialToBaseLendingRate locale dateFormat)

  # --- read -----------------------------------------------------------------------------------

  @doc "Every floating rate, by id, without its periods."
  @spec list() :: [map]
  def list, do: base() |> order_by([r], r.id) |> TenantRepo.all()

  @doc "One floating rate with its periods that are in use, latest first, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([r], r.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      rate -> {:ok, Map.put(rate, :periods, periods(id))}
    end
  end

  defp periods(rate_id) do
    from(p in "m_floating_rates_periods",
      left_join: c in "m_appuser",
      on: c.id == p.created_by,
      left_join: m in "m_appuser",
      on: m.id == p.last_modified_by,
      where: p.floating_rates_id == ^rate_id and p.is_active == true,
      order_by: [desc: p.from_date],
      select: %{
        id: p.id,
        from_date: p.from_date,
        interest_rate: p.interest_rate,
        differential: p.is_differential_to_base_lending_rate,
        active: p.is_active,
        created_by: c.username,
        created_on: p.created_on_utc,
        modified_by: m.username,
        modified_on: p.last_modified_on_utc
      }
    )
    |> TenantRepo.all()
  end

  defp base do
    from(r in "m_floating_rates",
      left_join: c in "m_appuser",
      on: c.id == r.created_by,
      left_join: m in "m_appuser",
      on: m.id == r.last_modified_by,
      select: %{
        id: r.id,
        name: r.name,
        base_lending_rate: r.is_base_lending_rate,
        active: r.is_active,
        created_by: c.username,
        created_on: r.created_on_utc,
        modified_by: m.username,
        modified_on: r.last_modified_on_utc
      }
    )
  end

  # --- write ----------------------------------------------------------------------------------

  @doc "Creates the floating rate `params` describe."
  @spec create!(Params.t(), map) :: Result.t()
  def create!(%Params{} = params, user) do
    request = read(params)
    check!(request, "createFloatingRate.floatingRateRequest.", nil)

    now = DateTime.utc_now()

    # a second floating rate of the same name is a data-integrity error Fineract reports as an unknown one
    {1, [%{id: id}]} =
      Integrity.translate(
        fn ->
          TenantRepo.insert_all(
            "m_floating_rates",
            [
              %{
                name: request.name,
                is_base_lending_rate: request.base == true,
                is_active: request.active != false,
                created_by: user.id,
                last_modified_by: user.id,
                created_date: DateTime.to_naive(now),
                lastmodified_date: DateTime.to_naive(now),
                created_on_utc: now,
                last_modified_on_utc: now
              }
            ],
            returning: [:id]
          )
        end,
        %{},
        {"error.msg.floatingrates.unknown.data.integrity.issue",
         "Unknown data integrity issue with resource."}
      )

    insert_periods!(id, request.periods || [], user, now)
    Result.new(resource_id: id)
  end

  @doc "Changes floating rate `id`. The result lists what changed (an empty list of changes is still shown)."
  @spec update!(integer, Params.t(), map) :: Result.t()
  def update!(id, %Params{} = params, user) do
    request = read(params)
    {:ok, rate} = fetch!(id)
    check!(request, "updateFloatingRate.floatingRateRequest.", rate)

    {changes, set} = changes(request, rate)
    now = DateTime.utc_now()

    if request.periods not in [nil, []] do
      replace_periods!(id, request.periods, user, now)
    end

    unless changes == %{} do
      save_changes!(
        id,
        set ++
          [
            last_modified_by: user.id,
            last_modified_on_utc: now,
            lastmodified_date: DateTime.to_naive(now)
          ]
      )
    end

    Result.new(resource_id: id, changes: changes)
  end

  # a name taken by another floating rate is an unhandled failure in Fineract here (a plain HTTP 500)
  defp save_changes!(id, set) do
    TenantRepo.update_all(from(r in "m_floating_rates", where: r.id == ^id), set: set)
  rescue
    error in Postgrex.Error -> name_taken!(error, __STACKTRACE__)
  end

  defp name_taken!(%{postgres: %{code: :unique_violation}}, _stacktrace),
    do: raise(ECBPlatform.Errors.ServerError)

  defp name_taken!(error, stacktrace), do: reraise(error, stacktrace)

  defp fetch!(id) do
    case get(id) do
      {:ok, rate} -> {:ok, rate}
      {:error, error} -> raise error
    end
  end

  # The request as a typed one holds it: only what Fineract lists, nulls dropped, booleans really booleans.
  defp read(params) do
    p = Params.typed(params, @fields)

    %{
      name: Params.string(p, "name"),
      raw_name: Params.value(p, "name"),
      base: boolean(p, "isBaseLendingRate"),
      active: boolean(p, "isActive"),
      periods: periods_of(Params.value(p, "ratePeriods"))
    }
  end

  defp boolean(p, key) do
    if Params.exists?(p, key), do: Params.strict_boolean(p, key)
  end

  defp periods_of(nil), do: nil

  defp periods_of(list) when is_list(list) do
    for item <- list do
      unless is_map(item), do: raise(InvalidJsonData)
      typed = Params.typed(%Params{map: item}, @period_fields)

      %{
        from: Params.value(typed, "fromDate"),
        rate: Params.decimal(typed, "interestRate"),
        differential: boolean(typed, "isDifferentialToBaseLendingRate"),
        format: Params.string(typed, "dateFormat"),
        locale: Params.string(typed, "locale"),
        echo: Map.new(typed.map)
      }
    end
  end

  defp periods_of(_other), do: raise(InvalidJsonData)

  defp changes(request, rate) do
    {%{}, []}
    |> change("name", request.name, rate.name, :name)
    |> change("isBaseLendingRate", request.base, rate.base_lending_rate, :is_base_lending_rate)
    |> change("isActive", request.active, rate.active, :is_active)
    |> periods_change(request)
  end

  defp change({changes, set}, _key, nil, _existing, _column), do: {changes, set}
  defp change({changes, set}, _key, same, same, _column), do: {changes, set}

  defp change({changes, set}, key, value, _existing, column),
    do: {Map.put(changes, key, value), set ++ [{column, value}]}

  defp periods_change({changes, set}, %{periods: periods}) when periods in [nil, []],
    do: {changes, set}

  defp periods_change({changes, set}, %{periods: periods}),
    do: {Map.put(changes, "ratePeriods", Enum.map(periods, & &1.echo)), set}

  # --- the checks Fineract makes of the request -----------------------------------------------

  # The problems of a request. Each is `{message key, property path}`; one found in a single field has the
  # name of the operation in front of its path, one found by the check of the whole request has it only on
  # create (as Fineract names them).
  defp check!(request, prefix, rate) do
    errors =
      field_errors(request, prefix) ++ request_errors(request, prefix, rate)

    if errors != [] do
      raise PlatformApiDataValidation, errors: Enum.map(errors, &violation/1)
    end

    :ok
  end

  defp field_errors(request, prefix) do
    name_errors(request, prefix) ++
      empty_periods(request, prefix) ++ period_fields(request, prefix)
  end

  defp name_errors(%{name: nil, raw_name: nil}, prefix)
       when prefix == "updateFloatingRate.floatingRateRequest.",
       do: []

  defp name_errors(%{name: nil}, prefix), do: [{"name.not-blank", prefix <> "name"}]

  defp name_errors(%{name: name}, prefix),
    do: if(String.length(name) > 200, do: [{"name.max", prefix <> "name"}], else: [])

  defp empty_periods(%{periods: []}, prefix),
    do: [{"rate-periods.not-empty", prefix <> "ratePeriods"}]

  defp empty_periods(_request, _prefix), do: []

  defp period_fields(%{periods: nil}, _prefix), do: []

  defp period_fields(%{periods: periods}, prefix) do
    periods
    |> Enum.with_index()
    |> Enum.flat_map(fn {period, index} ->
      path = prefix <> "ratePeriods[#{index}]."

      blank_date(period, path) ++ missing_or_negative_rate(period, path)
    end)
  end

  defp blank_date(%{from: from}, path) do
    if is_nil(from) or String.trim(to_string(from)) == "",
      do: [{"from-date.not-blank", path <> "fromDate"}],
      else: []
  end

  defp missing_or_negative_rate(%{rate: nil}, path),
    do: [{"interest-rate.not-null", path <> "interestRate"}]

  defp missing_or_negative_rate(%{rate: rate}, path),
    do:
      if(Decimal.negative?(rate),
        do: [{"interest-rate.positive-or-zero", path <> "interestRate"}],
        else: []
      )

  # the checks of the whole request: base lending rates and the dates and differentials of the periods
  defp request_errors(request, prefix, rate) do
    base = base_lending_rate()
    path = if rate, do: "", else: prefix

    base_errors(request, base, rate, path) ++ period_errors(request, base, rate, path)
  end

  defp base_lending_rate do
    TenantRepo.one(
      from(r in "m_floating_rates",
        where: r.is_base_lending_rate == true and r.is_active == true,
        select: r.id
      )
    )
  end

  # creating: a second base lending rate is refused
  defp base_errors(%{base: true}, base, nil, path) when not is_nil(base),
    do: [{"base-lending-rate.duplicate", path <> "isBaseLendingRate"}]

  # updating: another floating rate being the base is refused, and so is ceasing to be the base while rates are linked
  defp base_errors(request, base, rate, path) when not is_nil(rate) do
    duplicate =
      if request.base == true and base != nil and base != rate.id,
        do: [{"base-lending-rate.duplicate", path <> "isBaseLendingRate"}],
        else: []

    duplicate ++ linked_errors(request, base, rate, path)
  end

  defp base_errors(_request, _base, _rate, _path), do: []

  defp linked_errors(request, base, rate, path) do
    base? = if request.base != nil, do: request.base, else: rate.base_lending_rate
    active? = if request.active != nil, do: request.active, else: rate.active

    if base == rate.id and (not base? or not active?) and linked_to_base?(),
      do: [{"base-lending-rate.linked", path <> "isBaseLendingRate"}],
      else: []
  end

  # an active floating rate has an active period stated as a differential on the base lending rate
  defp linked_to_base? do
    TenantRepo.exists?(
      from(r in "m_floating_rates",
        join: p in "m_floating_rates_periods",
        on: p.floating_rates_id == r.id,
        where:
          r.is_active == true and p.is_active == true and
            p.is_differential_to_base_lending_rate == true
      )
    )
  end

  defp period_errors(%{periods: periods}, _base, _rate, _path) when periods in [nil, []], do: []

  defp period_errors(request, base, rate, path) do
    base? = if request.base != nil, do: request.base, else: rate && rate.base_lending_rate
    base_available? = base_available?(base, request, rate)

    {errors, dates} =
      request.periods
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {period, index}, {errors, dates} ->
        where = path <> "ratePeriods[#{index}]."
        {from_errors, dates} = from_date_errors(period, where, dates)

        {errors ++ from_errors ++ differential_errors(period, where, base?, base_available?),
         dates}
      end)

    errors ++
      if(length(dates) != length(Enum.uniq(dates)),
        do: [{"from-date.duplicate", path <> "ratePeriods"}],
        else: []
      )
  end

  # on create a base lending rate is there to differ from when one exists; on update, unless this rate is it
  # and is being switched off
  defp base_available?(base, _request, nil), do: base != nil

  defp base_available?(base, request, rate) do
    switched_off? =
      base == rate.id and
        ((request.base != nil and not request.base) or
           (request.active != nil and not request.active))

    base != nil and not switched_off?
  end

  defp from_date_errors(%{from: from} = period, where, dates) do
    if is_nil(from) or String.trim(to_string(from)) == "" do
      {[], dates}
    else
      case parse_date(from, period.format) do
        {:ok, date} -> {future_errors(date, where), dates ++ [date]}
        :error -> {[{"from-date.invalid", where <> "fromDate"}], dates}
      end
    end
  end

  defp future_errors(date, where) do
    if Date.compare(date, BusinessDate.current()) == :gt,
      do: [],
      else: [{"from-date.future", where <> "fromDate"}]
  end

  defp parse_date(text, nil),
    do:
      Date.from_iso8601(to_string(text)) |> then(&if(match?({:ok, _}, &1), do: &1, else: :error))

  defp parse_date(text, ""), do: parse_date(text, nil)
  defp parse_date(text, format), do: DatePattern.parse(to_string(text), format)

  defp differential_errors(%{differential: true}, where, base?, base_available?) do
    unavailable =
      if base_available?,
        do: [],
        else: [
          {"differential-to-base-lending-rate.not-available",
           where <> "isDifferentialToBaseLendingRate"}
        ]

    invalid =
      if base?,
        do: [
          {"differential-to-base-lending-rate.invalid-for-base-lending-rate",
           where <> "isDifferentialToBaseLendingRate"}
        ],
        else: []

    unavailable ++ invalid
  end

  defp differential_errors(_period, _where, _base?, _available?), do: []

  @messages %{
    "name.not-blank" => "The parameter 'name' is mandatory",
    "name.max" => "The parameter 'name' exceeds the maximum size of 200 characters",
    "rate-periods.not-empty" => "The parameter 'ratePeriods' cannot be empty",
    "from-date.not-blank" => "The parameter 'fromDate' is mandatory",
    "from-date.invalid" => "The parameter 'fromDate' is not a valid date",
    "from-date.future" => "The parameter 'fromDate' must be in the future",
    "from-date.duplicate" => "More than one entry in 'ratePeriods' has the same 'fromDate'",
    "interest-rate.not-null" => "The parameter 'interestRate' is mandatory",
    "interest-rate.positive-or-zero" => "The parameter 'interestRate' must be zero or positive",
    "base-lending-rate.duplicate" => "Base Lending Rate already exists",
    "base-lending-rate.linked" =>
      "There are floating rates linked to this Base Lending Rate, it cannot be marked as non-Base Lending Rate",
    "differential-to-base-lending-rate.not-available" => "Base Lending Rate doesn't exist",
    "differential-to-base-lending-rate.invalid-for-base-lending-rate" =>
      "The parameter 'isDifferentialToBaseLendingRate' cannot be true for a floating rate marked as Base Lending Rate"
  }

  defp violation({key, path}) do
    message = Map.fetch!(@messages, key)

    ECBPlatform.Errors.parameter_error(
      "org.apache.fineract.portfolio.floatingrate." <> key,
      message,
      path
    )
  end

  # --- periods --------------------------------------------------------------------------------

  defp insert_periods!(rate_id, periods, user, now) do
    for period <- periods do
      {:ok, from} = parse_date(period.from, period.format)

      TenantRepo.insert_all("m_floating_rates_periods", [
        %{
          floating_rates_id: rate_id,
          from_date: from,
          interest_rate: period.rate,
          is_differential_to_base_lending_rate: period.differential == true,
          is_active: true,
          created_by: user.id,
          last_modified_by: user.id,
          created_date: DateTime.to_naive(now),
          lastmodified_date: DateTime.to_naive(now),
          created_on_utc: now,
          last_modified_on_utc: now
        }
      ])
    end
  end

  # the periods that have not started are switched off, then the new series is added
  defp replace_periods!(rate_id, periods, user, now) do
    today = BusinessDate.current()

    TenantRepo.update_all(
      from(p in "m_floating_rates_periods",
        where: p.floating_rates_id == ^rate_id and p.from_date > ^today
      ),
      set: [is_active: false, last_modified_by: user.id, last_modified_on_utc: now]
    )

    insert_periods!(rate_id, periods, user, now)
  end

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.floatingrate.id.invalid",
        "Floating Rate with identifier #{id} does not exist",
        [id]
      )
end
