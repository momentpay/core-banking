defmodule ECBCatalog.Charges.Write do
  @moduledoc """
  Creating, changing and deleting charges, following Fineract's `ChargeDefinitionCommandFromApiJsonDeserializer`,
  `Charge` and `ChargeWritePlatformServiceJpaRepositoryImpl`.

  What a charge may be depends on what it applies to. A *loan* charge falls due at disbursement, on a date, per
  instalment, when overdue or at a tranche; a *savings* charge on a date, at activation, closure, withdrawal,
  weekly, monthly, annually, on overdraft or for no activity; a *client* charge on a date; a *share* charge at
  activation, purchase or redemption; a *working-capital loan* charge at disbursement or on a date. The way it is
  worked out narrows with the time. An overdue charge must be a penalty and a charge due at disbursement cannot
  be one. What a charge applies to never changes, and neither does its tax group once it has one.

  The request is read as a typed one: fields Fineract does not list (free-withdrawal settings, for one) are
  dropped before anything is checked. Runs inside a command's transaction.
  """
  import Ecto.Query

  alias ECBCatalog.{Charges, Taxes}
  alias ECBCatalog.Charges.Enums
  alias ECBLedger.GLAccounts
  alias ECBOrg.PaymentTypes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.{Errors, Integrity, Params, TenantRepo, Validation}
  alias ECBPlatform.Errors.{DomainRuleViolation, InvalidJsonData, PlatformApiDataValidation}
  alias ECBPlatform.Params.DatePattern

  @fields ~w(chargeAppliesTo name currencyCode chargeTimeType chargeCalculationType amount active penalty
             chargePaymentMode monthDayFormat locale feeOnMonthDay feeInterval feeFrequency paymentTypeId
             enablePaymentType minCap maxCap taxGroupId incomeAccountId)

  @savings_no_percent [5, 16]
  @loan_times [1, 2, 8, 9, 12]

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the charge `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    p = Params.typed(params, @fields)
    check_types!(p)

    {validation, c} = validate_create(p)
    Validation.raise_if_errors!(validation)

    account = c.account_id && GLAccounts.fetch!(c.account_id)
    tax_group = c.tax_group_id && Taxes.fetch_group!(c.tax_group_id)

    payment_type =
      if c.enable_payment_type and c.payment_type_id, do: PaymentTypes.fetch!(c.payment_type_id)

    "charges" |> Validation.new() |> entity_checks(c) |> Validation.raise_if_errors!()

    row = build(c, account, tax_group, payment_type)

    {1, [%{id: id}]} =
      Integrity.translate(
        fn -> TenantRepo.insert_all("m_charge", [row], returning: [:id]) end,
        %{
          "m_charge_name_key" =>
            {"error.msg.charge.duplicate.name", "Charge with name `#{c.name}` already exists",
             "name", [c.name]}
        },
        {"error.msg.charge.unknown.data.integrity.issue",
         "Unknown data integrity issue with resource."}
      )

    Result.new(resource_id: id)
  end

  # What the request asks for, and the problems with it (the checks follow what the charge applies to).
  defp validate_create(p) do
    applies = integer_sans_locale(p, "chargeAppliesTo")

    v =
      Validation.new("charge")
      |> Validation.param("chargeAppliesTo", applies)
      |> Validation.not_null()
      |> one_of_if_present("chargeAppliesTo", applies, Enums.applies_to_ids())

    calc = integer_sans_locale(p, "chargeCalculationType")
    v = v |> Validation.param("chargeCalculationType", calc) |> Validation.not_null()

    fee_interval = Params.integer_in_default_locale(p, "feeInterval")
    v = v |> Validation.param("feeInterval", fee_interval) |> Validation.greater_than_zero()

    fee_frequency = Params.integer_in_default_locale(p, "feeFrequency")
    v = v |> Validation.param("feeFrequency", fee_frequency) |> Validation.in_range(0, 3)

    {v, enable_payment_type, payment_type_id} = payment_type_checks(v, p)

    v =
      if fee_frequency,
        do: v |> Validation.param("feeInterval", fee_interval) |> Validation.not_null(),
        else: v

    {v, time, mode, month_day} = by_applies_to(v, p, applies, calc, fee_interval)

    name = Params.string(p, "name")
    currency = Params.string(p, "currencyCode")
    amount = amount(p)

    v =
      v
      |> Validation.param("name", name)
      |> Validation.not_blank()
      |> Validation.max_length(100)
      |> Validation.param("currencyCode", currency)
      |> Validation.not_blank()
      |> Validation.max_length(3)
      |> Validation.param("amount", amount)
      |> Validation.not_null()
      |> Validation.positive_amount()

    {v, penalty} = optional_boolean(v, p, "penalty")
    {v, active} = optional_boolean(v, p, "active")
    {v, min_cap} = optional_cap(v, p, "minCap")
    {v, max_cap} = optional_cap(v, p, "maxCap")

    {v, tax_group_id} =
      if Params.exists?(p, "taxGroupId") do
        id = Params.long(p, "taxGroupId")

        {v
         |> Validation.param("taxGroupId", id)
         |> Validation.not_null()
         |> Validation.greater_than_zero(), id}
      else
        {v, nil}
      end

    account_id = if Params.exists?(p, "incomeAccountId"), do: Params.long(p, "incomeAccountId")

    charge = %{
      name: name,
      amount: amount,
      currency: currency,
      applies_to: applies,
      time: time,
      calculation: calc,
      mode: mode,
      month_day: month_day,
      fee_interval: fee_interval,
      fee_frequency: fee_frequency,
      penalty: penalty,
      active: active,
      min_cap: min_cap,
      max_cap: max_cap,
      account_id: account_id,
      tax_group_id: tax_group_id,
      enable_payment_type: enable_payment_type,
      payment_type_id: payment_type_id
    }

    {v, charge}
  end

  defp payment_type_checks(v, p) do
    if Params.exists?(p, "enablePaymentType") do
      enable = Params.strict_boolean(p, "enablePaymentType")
      v = v |> Validation.param("enablePaymentType", enable) |> Validation.not_null()

      if enable do
        id = Params.integer_in_default_locale(p, "paymentTypeId")
        {v |> Validation.param("paymentTypeId", id) |> Validation.greater_than_zero(), enable, id}
      else
        {v, enable, nil}
      end
    else
      {v, false, nil}
    end
  end

  defp optional_boolean(v, p, key) do
    if Params.exists?(p, key) do
      value = Params.strict_boolean(p, key)
      {v |> Validation.param(key, value) |> Validation.not_null(), value == true}
    else
      {v, false}
    end
  end

  defp optional_cap(v, p, key) do
    if Params.exists?(p, key) do
      value = decimal_with_locale(p, key)

      {v |> Validation.param(key, value) |> Validation.not_null() |> Validation.positive_amount(),
       value}
    else
      {v, nil}
    end
  end

  # --- the checks that depend on what the charge applies to -----------------------------------

  defp by_applies_to(v, p, 1, calc, _fee_interval) do
    time = integer_sans_locale(p, "chargeTimeType")

    v =
      v
      |> Validation.param("chargeTimeType", time)
      |> Validation.not_null()
      |> one_of_if_present("chargeTimeType", time, Enums.loan_times())

    mode = integer_sans_locale(p, "chargePaymentMode")

    v =
      v
      |> Validation.param("chargePaymentMode", mode)
      |> Validation.not_null()
      |> Validation.one_of(Enums.payment_modes())
      |> one_of_if_present("chargePaymentMode", mode, Enums.payment_modes())
      |> one_of_if_present("chargeCalculationType", calc, Enums.loan_calculations())

    {if(time && calc, do: time_and_calculation(v, time, calc), else: v), time, mode, nil}
  end

  defp by_applies_to(v, p, 2, calc, fee_interval) do
    time = integer_sans_locale(p, "chargeTimeType")

    v =
      v
      |> Validation.param("chargeTimeType", time)
      |> Validation.not_null()
      |> one_of_if_present("chargeTimeType", time, Enums.savings_times())

    {v, month_day} = month_day_for(v, p, time, fee_interval)

    {one_of_if_present(v, "chargeCalculationType", calc, Enums.savings_calculations()), time,
     plain_mode(p), month_day}
  end

  defp by_applies_to(v, p, 3, calc, _fee_interval) do
    time = integer_sans_locale(p, "chargeTimeType")

    v =
      v
      |> Validation.param("chargeTimeType", time)
      |> Validation.not_null()
      |> one_of_if_present("chargeTimeType", time, Enums.client_times())
      |> one_of_if_present("chargeCalculationType", calc, Enums.client_calculations())

    v =
      if Params.exists?(p, "incomeAccountId") do
        id = Params.long(p, "incomeAccountId")

        v
        |> Validation.param("incomeAccountId", id)
        |> Validation.not_null()
        |> Validation.greater_than_zero()
      else
        v
      end

    {v, time, plain_mode(p), nil}
  end

  defp by_applies_to(v, p, 4, calc, _fee_interval) do
    time = integer_sans_locale(p, "chargeTimeType")

    v =
      v
      |> Validation.param("chargeTimeType", time)
      |> Validation.not_null()
      |> one_of_if_present("chargeTimeType", time, Enums.share_times())
      |> one_of_if_present("chargeCalculationType", calc, Enums.savings_calculations())

    v =
      if time == 13 and calc,
        do: v |> Validation.param("chargeCalculationType", calc) |> Validation.one_of([1]),
        else: v

    {v, time, plain_mode(p), nil}
  end

  defp by_applies_to(v, p, 5, calc, _fee_interval) do
    time = integer_sans_locale(p, "chargeTimeType")

    v =
      v
      |> Validation.param("chargeTimeType", time)
      |> Validation.not_null()
      |> one_of_if_present("chargeTimeType", time, Enums.working_capital_times())
      |> one_of_if_present(
        "chargeCalculationType",
        calc,
        Enums.working_capital_calculations(time)
      )

    mode =
      if Params.exists?(p, "chargePaymentMode"), do: integer_sans_locale(p, "chargePaymentMode")

    {one_of_if_present(v, "chargePaymentMode", mode, [0]), time, mode, nil}
  end

  # no kind of charge: nothing more to check (the kind itself has been refused)
  defp by_applies_to(v, _p, _applies, _calc, _fee_interval), do: {v, nil, nil, nil}

  # the mode of a charge that has no rule about it (it is read as it comes)
  defp plain_mode(p),
    do:
      if(Params.exists?(p, "chargePaymentMode"), do: integer_sans_locale(p, "chargePaymentMode"))

  # monthly, annual and weekly savings fees have their own rules about the day they fall on
  defp month_day_for(v, p, time, fee_interval) do
    case time do
      11 ->
        text = Params.string(p, "feeOnMonthDay")

        {v
         |> Validation.param("feeOnMonthDay", text)
         |> Validation.blank_when("chargeTimeType", time), nil}

      7 ->
        month_day = month_day(p, "feeOnMonthDay")

        {v
         |> Validation.param("feeOnMonthDay", month_day)
         |> Validation.not_null()
         |> Validation.param("feeInterval", fee_interval)
         |> Validation.not_null()
         |> Validation.in_range(1, 12), month_day}

      6 ->
        month_day = month_day(p, "feeOnMonthDay")
        {v |> Validation.param("feeOnMonthDay", month_day) |> Validation.not_null(), month_day}

      _ ->
        {v, nil}
    end
  end

  # A charge due at tranche disbursement is flat or a share of the disbursement; any other cannot be a share of
  # the disbursement.
  defp time_and_calculation(v, time, calc) do
    v =
      if time == 13,
        do: v |> Validation.param("chargeCalculationType", calc) |> Validation.one_of([1]),
        else: v

    if time == 12,
      do:
        v
        |> Validation.param("chargeCalculationType", calc)
        |> Validation.one_of(Enums.tranche_calculations()),
      else: v |> Validation.param("chargeCalculationType", calc) |> Validation.not_one_of([5])
  end

  # What the charge itself refuses once it has been put together.
  defp entity_checks(v, c) do
    case c.applies_to do
      2 -> savings_checks(v, c)
      1 -> loan_checks(v, c)
      _ -> v
    end
  end

  defp savings_checks(v, c) do
    v =
      if c.time in Enums.savings_times(),
        do: v,
        else: charges_error(v, "chargeTimeType", c.time, "not.allowed.charge.time.for.savings")

    v =
      if c.calculation in Enums.savings_calculations(),
        do: v,
        else:
          charges_error(
            v,
            "chargeCalculationType",
            c.calculation,
            "not.allowed.charge.calculation.type.for.savings"
          )

    if c.time not in @savings_no_percent and c.calculation == 2,
      do:
        charges_error(
          v,
          "chargeCalculationType",
          c.calculation,
          "savings.charge.calculation.type.percentage.allowed.only.for.withdrawal.or.NoActivity"
        ),
      else: v
  end

  defp loan_checks(v, c) do
    if c.penalty and c.time in [1, 12],
      do: raise_charge("error.msg.charge.due.at.disbursement.cannot.be.penalty", c.name)

    if not c.penalty and c.time == 9, do: raise_charge("error.msg.charge.must.be.penalty", c.name)

    if c.time in @loan_times,
      do: v,
      else: charges_error(v, "chargeTimeType", c.time, "not.allowed.charge.time.for.loan")
  end

  defp raise_charge(code, name),
    do:
      raise(DomainRuleViolation,
        code: code,
        message: "Charge '#{name}' is invalid.",
        args: [name, name]
      )

  # a problem named by a code alone, under the resource `charges`
  defp charges_error(v, parameter, value, code),
    do:
      Validation.add_error(
        v,
        "validation.msg.charges.#{code}",
        "Failed data validation due to: #{code}.",
        parameter,
        [value, []]
      )

  # the row to insert
  defp build(c, account, tax_group, payment_type) do
    %{
      name: c.name,
      amount: c.amount,
      currency_code: c.currency,
      charge_applies_to_enum: c.applies_to,
      charge_time_enum: c.time,
      charge_calculation_enum: c.calculation,
      charge_payment_mode_enum: payment_mode_for(c),
      fee_interval: c.fee_interval,
      fee_frequency: c.fee_frequency,
      is_penalty: c.penalty,
      is_active: c.active,
      is_deleted: false,
      is_free_withdrawal: false,
      income_or_liability_account_id: account && account.id,
      tax_group_id: tax_group && tax_group.id
    }
    |> Map.merge(day_columns(c))
    |> Map.merge(cap_columns(c))
    |> Map.merge(payment_type_columns(c, payment_type))
  end

  # the day a monthly or annual savings fee falls on
  defp day_columns(%{applies_to: 2, time: time, month_day: {month, day}}) when time in [6, 7],
    do: %{fee_on_month: month, fee_on_day: day}

  defp day_columns(_charge), do: %{fee_on_month: nil, fee_on_day: nil}

  # caps are kept only for a charge that is a share of an amount
  defp cap_columns(%{calculation: calculation} = c) when calculation in [2, 5],
    do: %{min_cap: c.min_cap, max_cap: c.max_cap}

  defp cap_columns(_charge), do: %{min_cap: nil, max_cap: nil}

  # a payment type is kept only on a savings charge that has one
  defp payment_type_columns(%{applies_to: 2}, %{id: id}),
    do: %{is_payment_type: true, payment_type_id: id}

  defp payment_type_columns(_charge, _payment_type),
    do: %{is_payment_type: false, payment_type_id: nil}

  # The mode a charge is stored with, whatever it applies to: what the request says (1 is an account transfer,
  # anything else regular), or regular for a working-capital charge that says nothing.
  defp payment_mode_for(%{mode: nil, applies_to: 5}), do: 0
  defp payment_mode_for(%{mode: nil}), do: nil
  defp payment_mode_for(%{mode: 1}), do: 1
  defp payment_mode_for(%{mode: _other}), do: 0

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes charge `id`. The result lists what changed (with the `locale` Fineract adds for numbers)."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    p = Params.typed(params, @fields)
    check_types!(p)
    validate_update!(p)

    {:ok, stored} = fetch_stored!(id)
    {changes, c, v} = apply_changes(p, stored)
    Validation.raise_if_errors!(v)

    time_and_calculation_valid!(c)
    guard_active_and_frequency!(id, c, changes)

    set = persistable(changes, c, p)

    unless changes == %{} do
      Integrity.translate(
        fn -> TenantRepo.update_all(from(ch in "m_charge", where: ch.id == ^id), set: set) end,
        %{
          "m_charge_name_key" =>
            {"error.msg.data.integrity.issue",
             "The request caused a data integrity issue to be fired by the database.", nil, []}
        },
        {"error.msg.data.integrity.issue",
         "The request caused a data integrity issue to be fired by the database."}
      )
    end

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  defp fetch_stored!(id) do
    case Charges.fetch_stored(id) do
      {:ok, row} -> {:ok, row}
      {:error, error} -> raise error
    end
  end

  defp validate_update!(p) do
    v = Validation.new("charge")

    v =
      v
      |> present(
        p,
        "name",
        &Params.string/2,
        &(&1 |> Validation.not_blank() |> Validation.max_length(100))
      )
      |> present(
        p,
        "currencyCode",
        &Params.string/2,
        &(&1 |> Validation.not_blank() |> Validation.max_length(3))
      )
      |> present(
        p,
        "amount",
        &decimal_with_locale/2,
        &(&1 |> Validation.not_null() |> Validation.positive_amount())
      )
      |> present(
        p,
        "minCap",
        &decimal_with_locale/2,
        &(&1 |> Validation.not_null() |> Validation.positive_amount())
      )
      |> present(
        p,
        "maxCap",
        &decimal_with_locale/2,
        &(&1 |> Validation.not_null() |> Validation.positive_amount())
      )

    # Fineract checks the kind of charge three times over, so a bad one is reported three times
    v =
      v
      |> applies_to_check(p)
      |> applies_to_check(p)
      |> applies_to_check(p)
      |> present(
        p,
        "chargeTimeType",
        &integer_sans_locale/2,
        &(&1 |> Validation.not_null() |> Validation.one_of(Enums.all_times()))
      )
      |> present(p, "feeOnMonthDay", &month_day/2, &Validation.not_null/1)
      |> present(
        p,
        "feeInterval",
        &Params.integer_in_default_locale/2,
        &Validation.greater_than_zero/1
      )
      |> present(
        p,
        "chargeCalculationType",
        &Params.integer_in_default_locale/2,
        &(&1 |> Validation.not_null() |> Validation.in_range(1, 5))
      )
      |> present(
        p,
        "chargePaymentMode",
        &Params.integer_in_default_locale/2,
        &Validation.in_range(&1, 0, 1)
      )
      |> present(p, "penalty", &Params.strict_boolean/2, &Validation.not_null/1)
      |> present(p, "active", &Params.strict_boolean/2, &Validation.not_null/1)
      |> present(
        p,
        "minCap",
        &decimal_with_locale/2,
        &(&1 |> Validation.not_null() |> Validation.positive_amount())
      )
      |> present(
        p,
        "maxCap",
        &decimal_with_locale/2,
        &(&1 |> Validation.not_null() |> Validation.positive_amount())
      )
      |> present(
        p,
        "feeFrequency",
        &Params.integer_in_default_locale/2,
        &Validation.in_range(&1, 0, 3)
      )
      |> present(
        p,
        "incomeAccountId",
        &Params.long/2,
        &(&1 |> Validation.not_null() |> Validation.greater_than_zero())
      )
      |> present(
        p,
        "taxGroupId",
        &Params.long/2,
        &(&1 |> Validation.not_null() |> Validation.greater_than_zero())
      )

    Validation.raise_if_errors!(v)
  end

  defp applies_to_check(v, p),
    do:
      present(v, p, "chargeAppliesTo", &integer_sans_locale/2, fn x ->
        x |> Validation.not_null() |> Validation.one_of(Enums.applies_to_ids())
      end)

  # runs `check` on `key` when the request names it
  defp present(v, p, key, read, check) do
    if Params.exists?(p, key), do: v |> Validation.param(key, read.(p, key)) |> check.(), else: v
  end

  # The charge as it is once the request is applied, what changed, and the problems found on the way.
  defp apply_changes(p, stored) do
    s = %{c: stored, changes: %{}, v: Validation.new("charges")}

    s =
      s
      |> change_text(p, "name", :name)
      |> change_text(p, "currencyCode", :currency_code)
      |> change_amount(p)
      |> change_time(p)
      |> change_payment_type(p)
      |> forbid_applies_to_change(p)
      |> change_calculation(p)
      |> check_working_capital()
      |> change_payment_mode(p)
      |> change_month_day(p)
      |> change_integer(p, "feeInterval", :fee_interval)
      |> change_integer(p, "feeFrequency", :fee_frequency)
      |> require_interval()
      |> change_flag(p, "penalty", :penalty)
      |> change_flag(p, "active", :active)
      |> change_caps(p)
      |> check_penalty_rules()
      |> change_reference(p, "incomeAccountId", :account_id)
      |> change_tax_group(p)

    {s.changes, s.c, s.v}
  end

  defp change_text(s, p, key, field) do
    if Params.changed_string?(p, key, Map.fetch!(s.c, field)) do
      value = Params.command_string(p, key)
      %{s | c: Map.put(s.c, field, value), changes: Map.put(s.changes, key, value)}
    else
      s
    end
  end

  defp change_amount(s, p) do
    if Params.exists?(p, "amount") and not Decimal.equal?(amount(p) || 0, s.c.amount) do
      value = amount(p)

      %{
        s
        | c: %{s.c | amount: value},
          changes: s.changes |> Map.put("amount", value) |> with_locale(p)
      }
    else
      s
    end
  end

  defp change_integer(s, p, key, field) do
    if Params.exists?(p, key) and
         Params.integer_in_default_locale(p, key) != Map.fetch!(s.c, field) do
      value = Params.integer_in_default_locale(p, key)

      %{
        s
        | c: Map.put(s.c, field, value),
          changes: s.changes |> Map.put(key, value) |> with_locale(p)
      }
    else
      s
    end
  end

  defp change_flag(s, p, key, field) do
    if Params.changed_boolean?(p, key, Map.fetch!(s.c, field)) do
      value = Params.strict_boolean(p, key) == true
      %{s | c: Map.put(s.c, field, value), changes: Map.put(s.changes, key, value)}
    else
      s
    end
  end

  # the language Fineract notes beside a changed number (the request has to name a locale)
  defp with_locale(changes, p) do
    case Params.locale(p) do
      nil -> raise ECBPlatform.Errors.ServerError
      locale -> Map.put(changes, "locale", locale |> String.split("_") |> hd())
    end
  end

  defp change_time(s, p) do
    if Params.exists?(p, "chargeTimeType") and
         integer_sans_locale(p, "chargeTimeType") != s.c.time do
      new = integer_sans_locale(p, "chargeTimeType")

      s = %{
        s
        | c: %{s.c | time: new},
          changes: s.changes |> Map.put("chargeTimeType", new) |> with_locale(p)
      }

      time_checks(s, p, new)
    else
      s
    end
  end

  defp time_checks(%{c: %{applies_to: 2}} = s, p, new) do
    s =
      if new in Enums.savings_times(),
        do: s,
        else: add_error(s, "chargeTimeType", new, "not.allowed.charge.time.for.savings")

    if new == 7 do
      month_day = month_day(p, "feeOnMonthDay")
      interval = Params.integer_in_default_locale(p, "feeInterval")

      v =
        s.v
        |> Validation.param("feeOnMonthDay", month_day)
        |> Validation.not_null()
        |> Validation.param("feeInterval", interval)
        |> Validation.not_null()
        |> Validation.in_range(1, 12)

      %{s | v: v}
    else
      s
    end
  end

  defp time_checks(%{c: %{applies_to: 1}} = s, _p, new) do
    if new in @loan_times,
      do: s,
      else: add_error(s, "chargeTimeType", new, "not.allowed.charge.time.for.loan")
  end

  defp time_checks(%{c: %{applies_to: 5}} = s, _p, new),
    do: %{
      s
      | v:
          s.v
          |> Validation.param("chargeTimeType", new)
          |> Validation.not_null()
          |> Validation.one_of(Enums.working_capital_times())
    }

  # (a client charge is held to the times a loan charge may have)
  defp time_checks(%{c: %{applies_to: 3}} = s, _p, new) do
    if new in @loan_times,
      do: s,
      else: add_error(s, "chargeTimeType", new, "not.allowed.charge.time.for.client")
  end

  defp time_checks(s, _p, _new), do: s

  defp add_error(s, parameter, value, code),
    do: %{s | v: charges_error(s.v, parameter, value, code)}

  defp change_payment_type(s, p) do
    s = change_flag(s, p, "enablePaymentType", :enable_payment_type)

    if Params.exists?(p, "paymentTypeId") and
         Params.long(p, "paymentTypeId") != s.c.payment_type_id do
      %{s | changes: Map.put(s.changes, "paymentTypeId", Params.long(p, "paymentTypeId"))}
    else
      s
    end
  end

  defp forbid_applies_to_change(s, p) do
    if Params.exists?(p, "chargeAppliesTo") and
         integer_sans_locale(p, "chargeAppliesTo") != s.c.applies_to do
      raise DomainRuleViolation,
        code: "error.msg.charge.update.of.charge.applies.to.is.not.supported",
        message: "Update of Charge applies to is not supported",
        args: []
    end

    s
  end

  defp change_calculation(s, p) do
    if Params.exists?(p, "chargeCalculationType") and
         Params.integer_in_default_locale(p, "chargeCalculationType") != s.c.calculation do
      new = Params.integer_in_default_locale(p, "chargeCalculationType")

      s = %{
        s
        | c: %{s.c | calculation: new},
          changes: s.changes |> Map.put("chargeCalculationType", new) |> with_locale(p)
      }

      calculation_checks(s, new)
    else
      s
    end
  end

  defp calculation_checks(%{c: %{applies_to: 2}} = s, new) do
    s =
      if new in Enums.savings_calculations(),
        do: s,
        else:
          add_error(
            s,
            "chargeCalculationType",
            new,
            "not.allowed.charge.calculation.type.for.savings"
          )

    if s.c.time not in @savings_no_percent and new == 2,
      do:
        add_error(
          s,
          "chargeCalculationType",
          new,
          "charge.calculation.type.percentage.allowed.only.for.withdrawal.or.noactivity"
        ),
      else: s
  end

  defp calculation_checks(%{c: %{applies_to: 3}} = s, new) do
    if new in Enums.client_calculations(),
      do: s,
      else:
        add_error(
          s,
          "chargeCalculationType",
          new,
          "not.allowed.charge.calculation.type.for.client"
        )
  end

  defp calculation_checks(s, _new), do: s

  defp check_working_capital(%{c: %{applies_to: 5}} = s) do
    if Map.has_key?(s.changes, "chargeTimeType") or
         Map.has_key?(s.changes, "chargeCalculationType") do
      v =
        s.v
        |> Validation.param("chargeCalculationType", s.c.calculation)
        |> Validation.not_null()
        |> Validation.one_of(Enums.working_capital_calculations(s.c.time))

      %{s | v: v}
    else
      s
    end
  end

  defp check_working_capital(s), do: s

  defp change_payment_mode(%{c: %{applies_to: applies}} = s, p) when applies in [1, 5] do
    if Params.exists?(p, "chargePaymentMode") do
      raw = Params.integer_in_default_locale(p, "chargePaymentMode")
      value = if applies == 5 and is_nil(raw), do: 0, else: raw
      before = length(s.v.errors)

      v =
        if applies == 5,
          do: s.v |> Validation.param("chargePaymentMode", value) |> Validation.one_of([0]),
          else: s.v |> Validation.param("chargePaymentMode", value) |> Validation.not_null()

      s = %{s | v: v}

      if length(v.errors) == before and value != s.c.payment_mode do
        %{
          s
          | c: %{s.c | payment_mode: value},
            changes: s.changes |> Map.put("chargePaymentMode", value) |> with_locale(p)
        }
      else
        s
      end
    else
      s
    end
  end

  defp change_payment_mode(s, _p), do: s

  # The day a monthly or annual fee falls on. A charge with no such day (a loan charge, say) crashes Fineract
  # here, and so it does here.
  defp change_month_day(s, p) do
    if Params.exists?(p, "feeOnMonthDay") do
      {month, day} = month_day(p, "feeOnMonthDay") || raise ECBPlatform.Errors.ServerError
      text = Params.string(p, "feeOnMonthDay")

      if is_nil(s.c.fee_on_day) or is_nil(s.c.fee_on_month),
        do: raise(ECBPlatform.Errors.ServerError)

      {s, noted?} =
        if s.c.fee_on_day != day,
          do: {%{s | c: %{s.c | fee_on_day: day}}, true},
          else: {s, false}

      {s, noted?} =
        if s.c.fee_on_month != month,
          do: {%{s | c: %{s.c | fee_on_month: month}}, true},
          else: {s, noted?}

      if noted?,
        do: %{s | changes: s.changes |> Map.put("feeOnMonthDay", text) |> with_locale(p)},
        else: s
    else
      s
    end
  end

  defp require_interval(s) do
    if s.c.fee_frequency,
      do: %{
        s
        | v: s.v |> Validation.param("feeInterval", s.c.fee_interval) |> Validation.not_null()
      },
      else: s
  end

  # caps belong to a charge worked out as a share of the amount
  defp change_caps(%{c: %{calculation: 2}} = s, p) do
    s
    |> change_cap(p, "minCap", :min_cap)
    |> change_cap(p, "maxCap", :max_cap)
  end

  defp change_caps(s, _p), do: s

  defp change_cap(s, p, key, field) do
    if Params.changed_decimal?(p, key, Map.fetch!(s.c, field)) do
      value = decimal_with_locale(p, key)

      %{
        s
        | c: Map.put(s.c, field, value),
          changes: s.changes |> Map.put(key, value) |> with_locale(p)
      }
    else
      s
    end
  end

  defp check_penalty_rules(%{c: c} = s) do
    if c.applies_to != 5 and c.penalty and c.time == 1,
      do: raise_charge("error.msg.charge.due.at.disbursement.cannot.be.penalty", c.name)

    if c.applies_to != 5 and not c.penalty and c.time == 9,
      do: raise_charge("error.msg.charge.must.be.penalty", c.name)

    s
  end

  defp change_reference(s, p, key, field) do
    if Params.exists?(p, key) and Params.long(p, key) != Map.fetch!(s.c, field) do
      %{s | changes: Map.put(s.changes, key, Params.long(p, key))}
    else
      s
    end
  end

  # a charge's tax group can be set once and never changed
  defp change_tax_group(s, p) do
    if Params.exists?(p, "taxGroupId") and Params.long(p, "taxGroupId") != s.c.tax_group_id do
      s = %{s | changes: Map.put(s.changes, "taxGroupId", Params.long(p, "taxGroupId"))}

      if s.c.tax_group_id,
        do: %{
          s
          | v:
              s.v
              |> Validation.param("taxGroupId", nil)
              |> Validation.fail_with_code("modification.not.supported")
        },
        else: s
    else
      s
    end
  end

  defp time_and_calculation_valid!(c) do
    Validation.new("charge")
    |> time_and_calculation(c.time, c.calculation)
    |> Validation.raise_if_errors!()
  end

  # A charge cannot be switched off while a product uses it, nor have its frequency changed.
  defp guard_active_and_frequency!(id, c, changes) do
    cond do
      Map.has_key?(changes, "active") ->
        if not c.active and Charges.used_by_products?(id),
          do:
            raise(DomainRuleViolation,
              code: "error.msg.charge.cannot.be.updated.it.is.used.in.loan",
              message: "This charge cannot be updated, it is used in loan",
              args: []
            )

      (Map.has_key?(changes, "feeFrequency") or Map.has_key?(changes, "feeInterval")) and
          c.applies_to == 1 ->
        if Charges.used_by_loan_products?(id),
          do:
            raise(DomainRuleViolation,
              code: "error.msg.charge.frequency.cannot.be.updated.it.is.used.in.loan",
              message: "This charge frequency cannot be updated, it is used in loan",
              args: []
            )

      true ->
        :ok
    end
  end

  # the columns to write, and the account, payment type and tax group the changes name (which have to exist)
  defp persistable(changes, c, p) do
    []
    |> put_if(changes, "name", name: c.name)
    |> put_if(changes, "currencyCode", currency_code: c.currency_code)
    |> put_if(changes, "amount", amount: c.amount)
    |> put_if(changes, "chargeTimeType", charge_time_enum: c.time)
    |> put_if(changes, "chargeCalculationType", charge_calculation_enum: c.calculation)
    |> put_if(changes, "chargePaymentMode", charge_payment_mode_enum: c.payment_mode)
    |> put_if(changes, "feeOnMonthDay", fee_on_day: c.fee_on_day, fee_on_month: c.fee_on_month)
    |> put_if(changes, "feeInterval", fee_interval: c.fee_interval)
    |> put_if(changes, "feeFrequency", fee_frequency: c.fee_frequency)
    |> put_if(changes, "penalty", is_penalty: c.penalty)
    |> put_if(changes, "active", is_active: c.active)
    |> put_if(changes, "minCap", min_cap: c.min_cap)
    |> put_if(changes, "maxCap", max_cap: c.max_cap)
    |> put_if(changes, "enablePaymentType", is_payment_type: c.enable_payment_type)
    |> account_column(changes, p)
    |> payment_type_column(changes, p)
    |> tax_group_column(changes, p)
  end

  defp put_if(set, changes, key, columns),
    do: if(Map.has_key?(changes, key), do: set ++ columns, else: set)

  defp account_column(set, changes, p) do
    if Map.has_key?(changes, "incomeAccountId") do
      id = Params.long(p, "incomeAccountId")
      set ++ [income_or_liability_account_id: id && GLAccounts.fetch!(id).id]
    else
      set
    end
  end

  defp payment_type_column(set, changes, p) do
    id = Params.long(p, "paymentTypeId")

    if Map.has_key?(changes, "paymentTypeId") and id,
      do: set ++ [payment_type_id: PaymentTypes.fetch!(id).id],
      else: set
  end

  defp tax_group_column(set, changes, p) do
    if Map.has_key?(changes, "taxGroupId") do
      id = Params.long(p, "taxGroupId")
      set ++ [tax_group_id: id && Taxes.fetch_group!(id).id]
    else
      set
    end
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes charge `id` (flags it and frees its name) when nothing uses it."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    {:ok, stored} = fetch_stored!(id)
    if stored.deleted, do: raise(Charges.not_found(id))

    if Charges.used?(id),
      do:
        raise(DomainRuleViolation,
          code: "error.msg.charge.cannot.be.deleted.it.is.already.used.in.loan",
          message: "This charge cannot be deleted, it is already used in loan",
          args: []
        )

    TenantRepo.update_all(from(c in "m_charge", where: c.id == ^id),
      set: [is_deleted: true, name: "#{id}_#{stored.name}"]
    )

    Result.new(resource_id: id)
  end

  # --- reading the request --------------------------------------------------------------------

  # The values Fineract's typed request refuses to hold: text where a true or false belongs.
  defp check_types!(p) do
    for key <- ~w(active penalty enablePaymentType),
        Params.exists?(p, key),
        do: Params.strict_boolean(p, key)

    :ok
  end

  # A whole number sent as a JSON number needs the request's locale to be read, even though it does not use it.
  defp integer_sans_locale(p, key) do
    case Params.value(p, key) do
      nil ->
        nil

      value ->
        if is_nil(Params.locale(p)),
          do: raise(PlatformApiDataValidation, errors: [missing_locale(key)])

        whole(value)
    end
  end

  defp whole(value) when is_integer(value), do: value
  defp whole(value) when is_float(value) and value == trunc(value), do: trunc(value)

  defp whole(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> raise InvalidJsonData
    end
  end

  defp whole(_value), do: raise(InvalidJsonData)

  defp missing_locale(key),
    do:
      Errors.parameter_error(
        "validation.msg.missing.locale.parameter",
        "The parameter `#{key}` requires a `locale` parameter to be passed with it.",
        key
      )

  # The amount arrives as a decimal number of the double kind, so a whole amount is 11.0 and not 11.
  defp amount(p) do
    case decimal_with_locale(p, "amount") do
      nil -> nil
      amount -> amount |> Decimal.to_float() |> Decimal.from_float()
    end
  end

  # A number needs the request's locale too: without one Fineract fails.
  defp decimal_with_locale(p, key) do
    if Params.value(p, key) != nil and is_nil(Params.locale(p)),
      do: raise(ECBPlatform.Errors.ServerError)

    Params.decimal(p, key)
  end

  defp one_of_if_present(v, _key, nil, _allowed), do: v

  defp one_of_if_present(v, key, value, allowed),
    do: v |> Validation.param(key, value) |> Validation.one_of(allowed)

  # The day and month a fee falls on, `{month, day}`, written as the request's `monthDayFormat` says.
  defp month_day(p, key) do
    case Params.string(p, key) do
      nil ->
        nil

      text ->
        format = Params.string(p, "monthDayFormat") || raise ECBPlatform.Errors.ServerError

        with_year = if String.contains?(format, ["y", "u"]), do: format, else: format <> " yyyy"
        shown = if with_year == format, do: text, else: text <> " 2000"

        case DatePattern.parse(shown, with_year) do
          {:ok, date} ->
            {date.month, date.day}

          :error ->
            # Fineract hands its error the value where the parameter belongs, so that is how it reads
            raise PlatformApiDataValidation,
              errors: [
                %{
                  code: "validation.msg.invalid.month.day",
                  developer_message:
                    "The parameter `#{key}` is invalid based on the monthDayFormat: `#{format}` and locale: `#{Params.locale(p)}` provided:",
                  default_message: key,
                  parameter: text,
                  args: [format]
                }
              ]
        end
    end
  end
end
