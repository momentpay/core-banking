defmodule ECBDeposits.DepositProducts.Write do
  @moduledoc """
  Creating, changing and deleting fixed deposit products, after Fineract's
  `FixedDepositProductWritePlatformServiceJpaRepositoryImpl`, `DepositProductAssembler`, `FixedDepositProduct` and
  `InterestRateChart`. A product is a savings product row with a term and pre-closure penalty and a list of
  interest rate charts; the rules it must satisfy as a whole (the term, the charts, how interest is posted and
  compounded) are asked once the pieces are put together. Must run inside a tenant scope.

  A product that keeps accounts in the ledger is mapped to its accounts as a savings product is. Recurring deposit
  products also carry the rules of their installments.
  """
  import Ecto.Query

  alias ECBDeposits.DepositProducts
  alias ECBDeposits.DepositProducts.{ChartChanges, TermChanges, Validate}
  alias ECBDeposits.{InterestCharts, SavingsProducts}
  alias ECBDeposits.SavingsProducts.Accounting
  alias ECBDeposits.SavingsProducts.Write, as: SavingsWrite
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.ServerError

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the deposit product `params` describe, with its term, charges and interest rate charts."
  @spec create!(:fixed | :recurring, Params.t()) :: Result.t()
  def create!(kind, %Params{} = p) do
    Validate.create!(kind, p)

    currency_code = Params.string(p, "currencyCode")
    charge_ids = SavingsWrite.charges!(p, currency_code)
    charts = p |> Params.value("charts") |> Enum.map(&InterestCharts.assemble/1)
    check_charts!(kind, charts)

    tax_group = SavingsWrite.tax_group!(p)
    row = product_row(kind, p, currency_code, tax_group)
    SavingsWrite.check_lockin!(row.lockin_period_frequency, row.lockin_period_frequency_enum)
    term = term_row(p)
    domain_rules!(kind, row, term, charts)

    {1, [%{id: id}]} =
      SavingsWrite.guard(p, fn ->
        TenantRepo.insert_all("m_savings_product", [row], returning: [:id])
      end)

    TenantRepo.insert_all("m_deposit_product_term_and_preclosure", [
      Map.put(term, :savings_product_id, id)
    ])

    if kind == :recurring, do: insert_recurring!(id, p)
    SavingsProducts.set_charges!(id, charge_ids)

    for chart <- Params.value(p, "charts") do
      InterestCharts.create!(id, chart, currency_code, nil)
    end

    # the books are mapped last, after the product and its charts are written
    Accounting.create!(id, p, Params.integer_in_default_locale(p, "accountingRule"))

    Result.new(resource_id: id)
  end

  defp product_row(kind, p, currency_code, tax_group) do
    rule = Params.integer_in_default_locale(p, "accountingRule")

    row = SavingsWrite.new_row(p, currency_code, rule)

    %{
      row
      | nominal_annual_interest_rate: row.nominal_annual_interest_rate || Decimal.new(0),
        deposit_type_enum: DepositProducts.type(kind)
    }
    |> Map.put(:tax_group_id, tax_group)
  end

  defp term_row(p) do
    applicable? =
      Params.exists?(p, "preClosurePenalApplicable") and
        Params.boolean(p, "preClosurePenalApplicable") == true

    %{
      pre_closure_penal_applicable: applicable?,
      pre_closure_penal_interest:
        if(applicable?, do: Params.decimal_with_locale(p, "preClosurePenalInterest")),
      pre_closure_penal_interest_on_enum:
        if(applicable?, do: Params.integer(p, "preClosurePenalInterestOnTypeId")),
      min_deposit_term: Params.integer(p, "minDepositTerm"),
      max_deposit_term: Params.integer(p, "maxDepositTerm"),
      min_deposit_term_type_enum: Params.integer(p, "minDepositTermTypeId"),
      max_deposit_term_type_enum: Params.integer(p, "maxDepositTermTypeId"),
      in_multiples_of_deposit_term: Params.integer(p, "inMultiplesOfDepositTerm"),
      in_multiples_of_deposit_term_type_enum: Params.integer(p, "inMultiplesOfDepositTermTypeId"),
      min_deposit_amount: amount(p, "minDepositAmount"),
      max_deposit_amount: amount(p, "maxDepositAmount"),
      deposit_amount: amount(p, "depositAmount")
    }
  end

  defp amount(p, key), do: if(Params.exists?(p, key), do: Params.decimal_with_locale(p, key))

  # the slabs of each chart, as the charts are put together
  defp check_charts!(kind, charts) do
    kind
    |> Validate.resource()
    |> Validation.new()
    |> then(fn v -> Enum.reduce(charts, v, &InterestCharts.validate_slabs(&2, &1)) end)
    |> Validation.raise_if_errors!()
  end

  # --- the rules of the whole product -----------------------------------------------------------

  defp domain_rules!(kind, row, term, charts) do
    kind
    |> Validate.resource()
    |> Validation.new()
    |> check_terms(term)
    |> InterestCharts.validate_dates(charts, BusinessDate.current())
    |> posting_and_compounding(
      row.interest_posting_period_enum,
      row.interest_compounding_period_enum
    )
    |> Validation.raise_if_errors!()
  end

  defp check_terms(v, term) do
    if term.min_deposit_term && term.max_deposit_term &&
         TermChanges.days(term.min_deposit_term, term.min_deposit_term_type_enum) >
           TermChanges.days(term.max_deposit_term, term.max_deposit_term_type_enum) do
      Validation.scoped(v, fn v ->
        v
        |> Validation.param("maxDepositTerm", term.max_deposit_term)
        |> Validation.fail_without_parameter("max.term.lessthan.min.term")
      end)
    else
      v
    end
  end

  # a posting period may not be shorter than the compounding period
  @compounds %{
    4 => [1, 4],
    5 => [1, 4, 5],
    6 => [1, 4, 5, 6],
    7 => [1, 4, 5, 6, 7],
    8 => [1, 4],
    9 => [1, 4, 5],
    10 => [1, 4, 5, 6],
    11 => [1, 4, 5, 6, 7]
  }

  @posting_names %{
    1 => "DAILY",
    4 => "MONTHLY",
    5 => "QUATERLY",
    6 => "BIANNUAL",
    7 => "ANNUAL",
    8 => "ANNIVERSARY_MONTHLY",
    9 => "ANNIVERSARY_QUARTERLY",
    10 => "ANNIVERSARY_BIANNUAL",
    11 => "ANNIVERSARY_ANNUAL"
  }

  @compounding_names %{
    1 => "DAILY",
    4 => "MONTHLY",
    5 => "QUATERLY",
    6 => "BI_ANNUAL",
    7 => "ANNUAL"
  }

  defp posting_and_compounding(v, posting, compounding) do
    if compounding in Map.get(@compounds, posting, []) do
      v
    else
      Validation.fail_without_parameter(
        v,
        "posting.period.type.is.less.than.compound.period.type",
        [
          Map.get(@posting_names, posting),
          Map.get(@compounding_names, compounding)
        ]
      )
    end
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes deposit product `id`; the result lists what changed."
  @spec update!(:fixed | :recurring, integer, Params.t()) :: Result.t()
  def update!(kind, id, %Params{} = p) do
    state =
      SavingsWrite.stored!(id, DepositProducts.manageable_types(kind), fn ->
        DepositProducts.not_found(kind, id)
      end)

    Validate.update!(kind, p)

    start = SavingsWrite.change_start(id, p, state)
    state = start.state
    term = stored_term(id)
    v = Validation.new(Validate.resource(kind))
    {term_changes, term, v} = TermChanges.change(p, term, v)
    {recurring_changes, recurring_columns} = change_recurring(kind, id, p)
    {chart_changes, chart_ops, v} = ChartChanges.change(id, p, v)

    v
    |> check_terms(term)
    |> posting_and_compounding(
      state.interest_posting_period_enum,
      state.interest_compounding_period_enum
    )
    |> Validation.raise_if_errors!()

    {changes, state} = SavingsWrite.change_finish!(start, id)
    rule_changed? = Map.has_key?(changes, "accountingRule")
    mapping_changes = Accounting.update!(id, p, state.accounting_type, rule_changed?, :deposit)
    changes = Map.merge(changes, mapping_changes)

    store_term!(id, term)
    store_recurring!(id, recurring_columns)
    Enum.each(chart_ops, &ChartChanges.run!/1)

    Result.new(
      resource_id: id,
      changes:
        changes
        |> Map.merge(term_changes)
        |> Map.merge(recurring_changes)
        |> Map.merge(chart_changes)
    )
  end

  # --- the rules of the installments of a recurring deposit ---------------------------------------

  @recurring_flags [
    {"isMandatoryDeposit", :is_mandatory},
    {"allowWithdrawal", :allow_withdrawal},
    {"adjustAdvanceTowardsFuturePayments", :adjust_advance_towards_future_payments}
  ]

  defp insert_recurring!(id, p) do
    row =
      Map.new(@recurring_flags, fn {key, column} -> {column, Params.boolean(p, key) == true} end)

    TenantRepo.insert_all("m_deposit_product_recurring_detail", [
      Map.put(row, :savings_product_id, id)
    ])
  end

  # a flag that is sent as null ends in an unhandled error; one that is not true or false changes nothing
  defp change_recurring(:recurring, id, p) do
    stored =
      TenantRepo.one(
        from(r in "m_deposit_product_recurring_detail",
          where: r.savings_product_id == ^id,
          select:
            map(r, [:is_mandatory, :allow_withdrawal, :adjust_advance_towards_future_payments])
        )
      )

    Enum.reduce(@recurring_flags, {%{}, []}, fn {key, column}, {changes, columns} ->
      cond do
        not Params.exists?(p, key) -> {changes, columns}
        Params.value(p, key) == nil -> raise ServerError
        true -> flag_change(p, key, column, stored, changes, columns)
      end
    end)
  end

  defp change_recurring(:fixed, _id, _p), do: {%{}, []}

  defp flag_change(p, key, column, stored, changes, columns) do
    case Params.boolean(p, key) do
      nil -> {changes, columns}
      new when new == :erlang.map_get(column, stored) -> {changes, columns}
      new -> {Map.put(changes, key, new), [{column, new} | columns]}
    end
  end

  defp store_recurring!(_id, []), do: :ok

  defp store_recurring!(id, columns) do
    TenantRepo.update_all(
      from(r in "m_deposit_product_recurring_detail", where: r.savings_product_id == ^id),
      set: columns
    )
  end

  defp stored_term(id) do
    TenantRepo.one(
      from(t in "m_deposit_product_term_and_preclosure",
        where: t.savings_product_id == ^id,
        select:
          map(t, [
            :pre_closure_penal_applicable,
            :pre_closure_penal_interest,
            :pre_closure_penal_interest_on_enum,
            :min_deposit_term,
            :max_deposit_term,
            :min_deposit_term_type_enum,
            :max_deposit_term_type_enum,
            :in_multiples_of_deposit_term,
            :in_multiples_of_deposit_term_type_enum,
            :min_deposit_amount,
            :max_deposit_amount,
            :deposit_amount
          ])
      )
    )
  end

  defp store_term!(id, term) do
    TenantRepo.update_all(
      from(t in "m_deposit_product_term_and_preclosure", where: t.savings_product_id == ^id),
      set: Map.to_list(term)
    )
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes deposit product `id`, with its term, charges and interest rate charts."
  @spec delete!(:fixed | :recurring, integer) :: Result.t()
  def delete!(kind, id) do
    unless DepositProducts.exists?(kind, id), do: raise(DepositProducts.not_found(kind, id))

    SavingsWrite.guard(nil, fn ->
      InterestCharts.delete_all!(id)

      TenantRepo.delete_all(
        from(t in "m_deposit_product_term_and_preclosure", where: t.savings_product_id == ^id)
      )

      TenantRepo.delete_all(
        from(r in "m_deposit_product_recurring_detail", where: r.savings_product_id == ^id)
      )

      TenantRepo.delete_all(
        from(c in "m_savings_product_charge", where: c.savings_product_id == ^id)
      )

      TenantRepo.delete_all(from(sp in "m_savings_product", where: sp.id == ^id))
    end)

    Result.new(resource_id: id)
  end
end
