defmodule ECBDeposits.SavingsProducts.Write do
  @moduledoc """
  Creating, changing and deleting savings products, following Fineract's
  `SavingsProductWritePlatformServiceJpaRepositoryImpl`, `SavingsProductAssembler` and the `SavingsProduct`
  entity.

  A product's charges must be active savings charges in the product's currency; its tax group must exist; a
  lock-in period needs its unit. When a product allows overdraft its overdraft figures default to zero; when
  it does not they are cleared. Deleting a product leaves its account mappings behind, as Fineract does.
  """
  import Ecto.Query

  alias ECBDeposits.SavingsProducts
  alias ECBDeposits.SavingsProducts.{Accounting, Validate}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Integrity, Json, Params, TenantRepo, Validation}

  @resource "savingsproduct"
  @savings_deposit 100

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the savings product `params` describe, with its charges and account mappings."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = p) do
    Validate.create!(p)

    currency_code = Params.string(p, "currencyCode")
    rule = Params.integer(p, "accountingRule")
    charge_ids = charges!(p, currency_code)
    row = new_row(p, currency_code, rule)
    row = Map.put(row, :tax_group_id, tax_group!(p))
    check_lockin!(row.lockin_period_frequency, row.lockin_period_frequency_enum)

    id = insert!(p, row)
    SavingsProducts.set_charges!(id, charge_ids)
    Accounting.create!(id, p, rule)
    Result.new(resource_id: id)
  end

  @doc false
  def new_row(p, currency_code, rule) do
    digits = Params.integer_with_locale(p, "digitsAfterDecimal")
    allow_overdraft = flag(p, "allowOverdraft")
    lockin_frequency = zero_to_nil(Params.integer_with_locale(p, "lockinPeriodFrequency"))
    lockin_type = Params.integer(p, "lockinPeriodFrequencyType")

    %{
      name: Params.command_string(p, "name"),
      short_name: Params.command_string(p, "shortName"),
      description: Params.string(p, "description"),
      deposit_type_enum: @savings_deposit,
      currency_code: currency_code,
      currency_digits: digits,
      currency_multiplesof: Params.integer_with_locale(p, "inMultiplesOf"),
      nominal_annual_interest_rate: Params.decimal_with_locale(p, "nominalAnnualInterestRate"),
      interest_compounding_period_enum: Params.integer(p, "interestCompoundingPeriodType"),
      interest_posting_period_enum: Params.integer(p, "interestPostingPeriodType"),
      interest_calculation_type_enum: Params.integer(p, "interestCalculationType"),
      interest_calculation_days_in_year_type_enum:
        Params.integer(p, "interestCalculationDaysInYearType"),
      min_required_opening_balance:
        round_to(zero_to_nil(Params.decimal_with_locale(p, "minRequiredOpeningBalance")), digits),
      lockin_period_frequency: lockin_frequency,
      lockin_period_frequency_enum: if(lockin_frequency && lockin_type, do: lockin_type),
      accounting_type: rule,
      withdrawal_fee_for_transfer: flag(p, "withdrawalFeeForTransfers"),
      allow_overdraft: allow_overdraft,
      overdraft_limit: zero_default(p, "overdraftLimit"),
      nominal_annual_interest_rate_overdraft:
        zero_default(p, "nominalAnnualInterestRateOverdraft"),
      min_overdraft_for_interest_calculation:
        zero_default(p, "minOverdraftForInterestCalculation"),
      min_required_balance: zero_default(p, "minRequiredBalance"),
      enforce_min_required_balance: flag(p, "enforceMinRequiredBalance"),
      is_lien_allowed: flag(p, "lienAllowed"),
      max_allowed_lien_limit: lien_limit(p),
      min_balance_for_interest_calculation:
        zero_to_nil(Params.decimal_with_locale(p, "minBalanceForInterestCalculation")),
      withhold_tax: flag(p, "withHoldTax"),
      is_dormancy_tracking_active: Params.boolean(p, "isDormancyTrackingActive") || false,
      days_to_inactive: Json.long(p, "daysToInactive"),
      days_to_dormancy: Json.long(p, "daysToDormancy"),
      days_to_escheat: Json.long(p, "daysToEscheat")
    }
    |> ensure_overdraft_limits()
  end

  # a parameter that is left out is zero; one that is sent blank is nothing
  defp zero_default(p, key),
    do: if(Params.exists?(p, key), do: Params.decimal_with_locale(p, key), else: Decimal.new(0))

  defp lien_limit(p) do
    if Params.exists?(p, "maxAllowedLienLimit"),
      do: zero_to_nil(Params.decimal_with_locale(p, "maxAllowedLienLimit")),
      else: Decimal.new(0)
  end

  @doc false
  def flag(p, key), do: Params.boolean(p, key) == true

  @doc false
  def zero_to_nil(nil), do: nil
  def zero_to_nil(0), do: nil

  def zero_to_nil(%Decimal{} = d), do: if(Decimal.equal?(d, 0), do: nil, else: d)
  def zero_to_nil(other), do: other

  defp round_to(nil, _digits), do: nil
  defp round_to(value, digits), do: Decimal.round(value, digits, :half_even)

  # a product that allows overdraft always has its overdraft figures
  defp ensure_overdraft_limits(%{allow_overdraft: true} = row) do
    Enum.reduce(
      [
        :overdraft_limit,
        :nominal_annual_interest_rate_overdraft,
        :min_overdraft_for_interest_calculation
      ],
      row,
      fn key, row -> Map.update!(row, key, &(&1 || Decimal.new(0))) end
    )
  end

  defp ensure_overdraft_limits(row), do: row

  # --- charges and tax group ---------------------------------------------------------------------

  # the charges named in the request (by `id`) as ids, each of which must suit a savings product in the currency
  @doc false
  def charges!(p, currency_code) do
    case Params.value(p, "charges") do
      list when is_list(list) ->
        for %{"id" => raw} <- list,
            do: charge!(Json.long(%Params{map: %{"id" => raw}}, "id"), currency_code)

      _ ->
        []
    end
  end

  defp charge!(id, currency_code) do
    row =
      TenantRepo.one(
        from(c in "m_charge",
          where: c.id == ^id,
          select: %{
            id: c.id,
            name: c.name,
            applies_to: c.charge_applies_to_enum,
            currency: c.currency_code,
            deleted: c.is_deleted,
            active: c.is_active
          }
        )
      )

    cond do
      row == nil or row.deleted ->
        raise ResourceNotFound,
          code: "error.msg.charge.id.invalid",
          message: "Charge with identifier #{id} does not exist",
          args: [id]

      not row.active ->
        raise DomainRuleViolation,
          code: "error.msg.charge.is.not.active",
          message: "Charge '#{row.name}' with identifier #{id} is not active",
          args: [row.name, id]

      row.applies_to != 2 ->
        raise DomainRuleViolation,
          code: "error.msg.charge.cannot.be.applied.tosavings.product",
          message: "Charge with identifier #{id} cannot be applied to Savings product.",
          args: [id]

      row.currency != currency_code ->
        raise DomainRuleViolation,
          code: "error.msg.charge.attach.to.savings.product.invalid.currency",
          message: "Charge and Savings Product must have the same currency.",
          args: []

      true ->
        id
    end
  end

  @doc false
  def tax_group!(p) do
    case Json.long(p, "taxGroupId") do
      nil -> nil
      id -> existing_tax_group!(id)
    end
  end

  defp existing_tax_group!(id) do
    if TenantRepo.exists?(from(t in "m_tax_group", where: t.id == ^id)) do
      id
    else
      raise ResourceNotFound,
        code: "error.msg.tax.group.id.invalid",
        message: "tax group with identifier #{id} does not exist",
        args: [id]
    end
  end

  # a lock-in period needs its unit, and a unit needs a period
  @doc false
  def check_lockin!(frequency, type) do
    Validation.new(@resource)
    |> lockin_problems(frequency, type)
    |> Validation.raise_if_errors!()
  end

  defp lockin_problems(v, nil, type) do
    v
    |> Validation.param("lockinPeriodFrequencyType", type)
    |> Validation.ignore_if_null()
    |> Validation.in_range(0, 3)
    |> unit_without_period(type)
  end

  defp lockin_problems(v, _frequency, type) do
    v
    |> Validation.param("lockinPeriodFrequency", type)
    |> Validation.zero_or_greater()
    |> Validation.param("lockinPeriodFrequencyType", type)
    |> Validation.not_null()
    |> Validation.in_range(0, 3)
  end

  defp unit_without_period(v, nil), do: v

  defp unit_without_period(v, _type),
    do: v |> Validation.param("lockinPeriodFrequency", nil) |> Validation.not_null()

  # --- storing ----------------------------------------------------------------------------------

  defp insert!(p, row) do
    {1, [%{id: id}]} =
      guard(p, fn -> TenantRepo.insert_all("m_savings_product", [row], returning: [:id]) end)

    id
  end

  # Fineract looks for its own constraint names in the database's message, which PostgreSQL's names never
  # contain, so a duplicate name or short name is an unknown data-integrity problem there too.
  @doc false
  def guard(_p, fun) do
    Integrity.translate(
      fun,
      %{},
      {"error.msg.savingsproduct.unknown.data.integrity.issue",
       "Unknown data integrity issue with savings product."}
    )
  end

  # --- update ---------------------------------------------------------------------------------

  @columns ~w(name short_name description currency_code currency_digits currency_multiplesof
              nominal_annual_interest_rate interest_compounding_period_enum interest_posting_period_enum
              interest_calculation_type_enum interest_calculation_days_in_year_type_enum
              min_required_opening_balance lockin_period_frequency lockin_period_frequency_enum
              accounting_type withdrawal_fee_for_transfer allow_overdraft overdraft_limit
              nominal_annual_interest_rate_overdraft min_overdraft_for_interest_calculation
              min_required_balance enforce_min_required_balance min_balance_for_interest_calculation
              withhold_tax tax_group_id is_dormancy_tracking_active days_to_inactive days_to_dormancy
              days_to_escheat max_allowed_lien_limit is_lien_allowed)a

  @doc "Changes savings product `id`; the result lists what changed."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = p) do
    state = stored!(id)

    Validate.update!(p, %{
      accounting_id: state.accounting_type,
      dormancy_tracking_active: state.is_dormancy_tracking_active,
      days_to_inactive: state.days_to_inactive,
      days_to_dormancy: state.days_to_dormancy,
      days_to_escheat: state.days_to_escheat
    })

    {changes, state} = change!(id, p, state)

    rule_changed? = Map.has_key?(changes, "accountingRule")
    mapping_changes = Accounting.update!(id, p, state.accounting_type, rule_changed?)

    Result.new(resource_id: id, changes: Map.merge(changes, mapping_changes))
  end

  @doc false
  # What a request changes in the product itself (not its accounting), stored; answers the changes and the state.
  @spec change!(integer, Params.t(), map) :: {map, map}
  def change!(id, %Params{} = p, state), do: id |> change_start(p, state) |> change_finish!(id)

  @doc false
  # The changes the request makes to the fields of the product, before its charges and tax group are looked up.
  @spec change_start(integer, Params.t(), map) :: map
  def change_start(_id, %Params{} = p, state) do
    acc = %{p: p, changes: %{}, set: [], state: state, locale: Params.locale(p) || ""}
    acc = apply_changes(acc)
    check_lockin!(acc.state.lockin_period_frequency, acc.state.lockin_period_frequency_enum)
    acc
  end

  @doc false
  # Looks up the charges and the tax group the change names and stores the product.
  @spec change_finish!(map, integer) :: {map, map}
  def change_finish!(acc, id) do
    {changes, state} = charges_and_tax!(acc, id)

    set =
      acc.set
      |> Enum.reverse()
      |> Enum.uniq_by(&elem(&1, 0))
      |> Keyword.merge(state_columns(state))

    unless set == [], do: store!(acc.p, id, set)
    {changes, state}
  end

  @doc false
  # The product as stored, to be changed, or the error for one that does not exist.
  @spec stored!(integer, integer, (-> Exception.t())) :: map
  def stored!(id, type \\ @savings_deposit, not_found \\ nil) do
    row =
      TenantRepo.one(
        from(sp in "m_savings_product",
          where: sp.id == ^id and sp.deposit_type_enum in ^List.wrap(type),
          select: map(sp, ^@columns)
        )
      ) || raise(if(not_found, do: not_found.(), else: SavingsProducts.not_found(id)))

    Map.update!(row, :lockin_period_frequency, &SavingsProducts.whole/1)
  end

  defp store!(p, id, set) do
    guard(p, fn ->
      TenantRepo.update_all(from(sp in "m_savings_product", where: sp.id == ^id), set: set)
    end)
  end

  # the columns the entity leaves in a state of its own making (cleared overdraft figures, a dropped tax group)
  defp state_columns(state),
    do:
      Enum.map(
        ~w(lockin_period_frequency_enum overdraft_limit nominal_annual_interest_rate_overdraft
           min_overdraft_for_interest_calculation tax_group_id days_to_inactive days_to_dormancy
           days_to_escheat)a,
        &{&1, Map.fetch!(state, &1)}
      )

  # What the request changes in the product, in the order Fineract looks.
  defp apply_changes(acc) do
    acc
    |> text("name", :name, :name)
    |> text("shortName", :short_name, :name)
    |> text("description", :description, :description)
    |> number("digitsAfterDecimal", :currency_digits, :int)
    |> text("currencyCode", :currency_code, :currency_code)
    |> number("inMultiplesOf", :currency_multiplesof, :int)
    |> number("nominalAnnualInterestRate", :nominal_annual_interest_rate, :decimal)
    |> number("interestCompoundingPeriodType", :interest_compounding_period_enum, :enum)
    |> number("interestPostingPeriodType", :interest_posting_period_enum, :enum)
    |> number("interestCalculationType", :interest_calculation_type_enum, :enum)
    |> number(
      "interestCalculationDaysInYearType",
      :interest_calculation_days_in_year_type_enum,
      :enum
    )
    |> number("minRequiredOpeningBalance", :min_required_opening_balance, :zero_decimal)
    |> number("lockinPeriodFrequency", :lockin_period_frequency, :zero_int)
    |> number("lockinPeriodFrequencyType", :lockin_period_frequency_enum, :enum)
    |> clear_lockin_type()
    |> boolean("withdrawalFeeForTransfers", :withdrawal_fee_for_transfer)
    |> number("accountingRule", :accounting_type, :enum)
    |> charges_change()
    |> boolean("allowOverdraft", :allow_overdraft)
    |> number("overdraftLimit", :overdraft_limit, :zero_decimal)
    |> number(
      "nominalAnnualInterestRateOverdraft",
      :nominal_annual_interest_rate_overdraft,
      :zero_decimal
    )
    |> number(
      "minOverdraftForInterestCalculation",
      :min_overdraft_for_interest_calculation,
      :zero_decimal
    )
    |> clear_overdraft()
    |> boolean("enforceMinRequiredBalance", :enforce_min_required_balance)
    |> number("minRequiredBalance", :min_required_balance, :zero_decimal)
    |> boolean("lienAllowed", :is_lien_allowed)
    |> number("maxAllowedLienLimit", :max_allowed_lien_limit, :zero_decimal)
    |> number(
      "minBalanceForInterestCalculation",
      :min_balance_for_interest_calculation,
      :zero_decimal
    )
    |> boolean("withHoldTax", :withhold_tax)
    |> tax_group_change()
    |> boolean("isDormancyTrackingActive", :is_dormancy_tracking_active)
    |> number("daysToInactive", :days_to_inactive, :long)
    |> number("daysToDormancy", :days_to_dormancy, :long)
    |> number("daysToEscheat", :days_to_escheat, :long)
    |> clear_dormancy()
    |> ensure_overdraft_state()
  end

  # The `shortName` is compared with the name, as Fineract does, so it is "changed" whenever it differs from it.
  defp text(acc, key, column, compare_with) do
    p = acc.p
    existing = Map.fetch!(acc.state, compare_with)

    if Params.changed_string?(p, key, existing) do
      value = Params.command_string(p, key)
      record(acc, key, column, value, value)
    else
      acc
    end
  end

  defp number(acc, key, column, kind) do
    p = acc.p

    if Params.exists?(p, key) do
      value = read(p, key, kind)
      existing = Map.fetch!(acc.state, column)

      if differs?(existing, value),
        do: acc |> record(key, column, value, value) |> with_locale(key, kind),
        else: acc
    else
      acc
    end
  end

  # the locale is shown with the numbers that are read with it
  defp with_locale(acc, key, kind) do
    if kind in [:int, :decimal, :zero_decimal, :zero_int] and key != "lockinPeriodFrequencyType",
      do: %{acc | changes: Map.put(acc.changes, "locale", acc.locale)},
      else: acc
  end

  defp read(p, key, :int), do: Params.integer_with_locale(p, key)
  defp read(p, key, :enum), do: Params.integer_with_locale(p, key)
  defp read(p, key, :zero_int), do: p |> Params.integer_with_locale(key) |> zero_to_nil()
  defp read(p, key, :decimal), do: Params.decimal_with_locale(p, key)
  defp read(p, key, :zero_decimal), do: p |> Params.decimal_with_locale(key) |> zero_to_nil()
  defp read(p, key, :long), do: Json.long(p, key)

  defp differs?(nil, nil), do: false
  defp differs?(nil, _), do: true
  defp differs?(_, nil), do: true
  defp differs?(%Decimal{} = a, %Decimal{} = b), do: not Decimal.equal?(a, b)
  defp differs?(%Decimal{} = a, b) when is_integer(b), do: not Decimal.equal?(a, b)
  defp differs?(a, b), do: a != b

  defp boolean(acc, key, column) do
    p = acc.p

    if Params.exists?(p, key) do
      raw = Params.boolean(p, key)
      existing = Map.fetch!(acc.state, column)

      if differs?(existing, raw),
        do: record(acc, key, column, raw == true, raw == true),
        else: acc
    else
      acc
    end
  end

  defp record(acc, key, column, shown, stored) do
    %{
      acc
      | changes: Map.put(acc.changes, key, shown),
        set: [{column, stored} | acc.set],
        state: Map.put(acc.state, column, stored)
    }
  end

  defp clear_lockin_type(acc) do
    if acc.state.lockin_period_frequency == nil,
      do: %{acc | state: %{acc.state | lockin_period_frequency_enum: nil}},
      else: acc
  end

  defp charges_change(acc) do
    if is_list(Params.value(acc.p, "charges")),
      do: %{
        acc
        | changes: Map.put(acc.changes, "charges", Params.fragment(acc.p, "charges"))
      },
      else: acc
  end

  defp clear_overdraft(acc) do
    if acc.state.allow_overdraft == true do
      acc
    else
      %{
        acc
        | state: %{
            acc.state
            | overdraft_limit: nil,
              nominal_annual_interest_rate_overdraft: nil,
              min_overdraft_for_interest_calculation: nil
          }
      }
    end
  end

  defp ensure_overdraft_state(acc) do
    %{acc | state: ensure_overdraft_limits(acc.state)}
  end

  # With tax withheld, a tax group that is new or different is a change; without it the group is dropped.
  defp tax_group_change(acc) do
    p = acc.p

    cond do
      acc.state.withhold_tax != true ->
        %{acc | state: %{acc.state | tax_group_id: nil}}

      acc.state.tax_group_id == nil or
          (Params.exists?(p, "taxGroupId") and
             differs?(acc.state.tax_group_id, Json.long(p, "taxGroupId"))) ->
        %{acc | changes: Map.put(acc.changes, "taxGroupId", Json.long(p, "taxGroupId"))}

      true ->
        acc
    end
  end

  defp clear_dormancy(acc) do
    if acc.state.is_dormancy_tracking_active == true do
      acc
    else
      %{
        acc
        | state: %{acc.state | days_to_inactive: nil, days_to_dormancy: nil, days_to_escheat: nil}
      }
    end
  end

  # The charges and the tax group a change names are looked up and checked once the rest is changed.
  defp charges_and_tax!(acc, id) do
    {changes, state} = {acc.changes, acc.state}
    changes = replace_charges!(changes, acc.p, id, state.currency_code)
    tax_group!(changes, acc.p, state)
  end

  defp replace_charges!(changes, p, id, currency_code) do
    if Map.has_key?(changes, "charges") do
      wanted = p |> charges!(currency_code) |> Enum.uniq() |> Enum.sort()

      if wanted == SavingsProducts.charge_ids(id) do
        Map.delete(changes, "charges")
      else
        SavingsProducts.set_charges!(id, wanted)
        changes
      end
    else
      changes
    end
  end

  defp tax_group!(changes, p, state) do
    if Map.has_key?(changes, "taxGroupId") do
      group = tax_group!(p)

      if state.withhold_tax == true and group == nil do
        Validation.new(@resource)
        |> Validation.param("taxGroupId", nil)
        |> Validation.not_blank()
        |> Validation.raise_if_errors!()
      end

      {changes, %{state | tax_group_id: group}}
    else
      {changes, state}
    end
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes savings product `id`."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    _product = SavingsProducts.fetch!(id)

    guard(nil, fn ->
      TenantRepo.delete_all(
        from(c in "m_savings_product_charge", where: c.savings_product_id == ^id)
      )

      TenantRepo.delete_all(from(sp in "m_savings_product", where: sp.id == ^id))
    end)

    Result.new(resource_id: id)
  end
end
