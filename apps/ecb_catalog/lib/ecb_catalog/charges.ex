defmodule ECBCatalog.Charges do
  @moduledoc """
  Charges (`m_charge`), read side, following Fineract's `ChargeReadPlatformServiceImpl`.

  A charge is a fee or a penalty a product can apply: to a loan, a savings account, a client, shares or a
  working-capital loan. It has an amount, a currency, a time it falls due, a way of working it out and,
  optionally, an income account and a tax group. Charges are deleted softly (flagged, and their name freed),
  and a charge in a currency the organisation has not selected is hidden from every read, as in Fineract.
  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBCatalog.Charges.Enums
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "Every charge that is not deleted, by name."
  @spec list() :: [map]
  def list,
    do:
      base()
      |> where([c], c.is_deleted == false)
      |> order_by([c], c.name)
      |> TenantRepo.all()
      |> Enum.map(&finish/1)

  @doc "One charge, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([c], c.id == ^id and c.is_deleted == false) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "The active charges a savings product carries."
  @spec for_savings_product(integer) :: [map]
  def for_savings_product(product_id) do
    base()
    |> join(:inner, [c], spc in "m_savings_product_charge", on: spc.charge_id == c.id)
    |> where(
      [c, ..., spc],
      c.is_deleted == false and c.is_active == true and spc.savings_product_id == ^product_id
    )
    |> order_by([c], c.id)
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc "The active charges a savings product can pick from, by name (`fee_only` leaves the penalties out)."
  @spec applicable_to_savings(boolean) :: [map]
  def applicable_to_savings(fee_only?) do
    base()
    |> where([c], c.is_deleted == false and c.is_active == true and c.charge_applies_to_enum == 2)
    |> then(fn q -> if fee_only?, do: where(q, [c], c.is_penalty == false), else: q end)
    |> order_by([c], c.name)
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc "The active penalties a savings product can pick from, by name."
  @spec savings_penalties() :: [map]
  def savings_penalties do
    base()
    |> where(
      [c],
      c.is_deleted == false and c.is_active == true and c.is_penalty == true and
        c.charge_applies_to_enum == 2
    )
    |> order_by([c], c.name)
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc """
  The stored charge, deleted or not and in any currency, for work that changes it; or
  `{:error, ResourceNotFound}`.
  """
  @spec fetch_stored(integer) :: {:ok, map} | {:error, Exception.t()}
  def fetch_stored(id) do
    row =
      from(c in "m_charge",
        where: c.id == ^id,
        select: %{
          id: c.id,
          name: c.name,
          amount: c.amount,
          currency_code: c.currency_code,
          applies_to: c.charge_applies_to_enum,
          time: c.charge_time_enum,
          calculation: c.charge_calculation_enum,
          payment_mode: c.charge_payment_mode_enum,
          fee_on_day: c.fee_on_day,
          fee_interval: c.fee_interval,
          fee_on_month: c.fee_on_month,
          fee_frequency: c.fee_frequency,
          penalty: c.is_penalty,
          active: c.is_active,
          deleted: c.is_deleted,
          min_cap: c.min_cap,
          max_cap: c.max_cap,
          enable_payment_type: c.is_payment_type,
          payment_type_id: c.payment_type_id,
          account_id: c.income_or_liability_account_id,
          tax_group_id: c.tax_group_id
        }
      )
      |> TenantRepo.one()

    if row, do: {:ok, row}, else: {:error, not_found(id)}
  end

  @doc "True when a loan product, a loan, a savings product or account, or a working-capital loan uses the charge."
  @spec used?(integer) :: boolean
  def used?(id) do
    Enum.any?(
      [
        {"m_product_loan_charge", ""},
        {"m_loan_charge", " AND is_active = true"},
        {"m_savings_account_charge", " AND is_active = true"},
        {"m_savings_product_charge", ""},
        {"m_wc_loan_charge", ""}
      ],
      fn {table, condition} -> used_in?(table, condition, id) end
    )
  end

  @doc "True when a loan product or a savings product has the charge (its use cannot be switched off)."
  @spec used_by_products?(integer) :: boolean
  def used_by_products?(id),
    do: used_by_loan_products?(id) or used_in?("m_savings_product_charge", "", id)

  @doc "True when a loan product has the charge."
  @spec used_by_loan_products?(integer) :: boolean
  def used_by_loan_products?(id), do: used_in?("m_product_loan_charge", "", id)

  # a table that does not exist yet (its product is built later) has nothing that uses the charge
  defp used_in?(table, condition, id),
    do:
      table?(table) and
        TenantRepo.query!("SELECT 1 FROM #{table} WHERE charge_id = $1#{condition} LIMIT 1", [id]).num_rows >
          0

  defp table?(name),
    do:
      TenantRepo.exists?(
        from(t in "tables",
          prefix: "information_schema",
          where: t.table_name == ^name and t.table_schema == "public"
        )
      )

  @doc """
  What a form for a new charge offers. `applies_to` 5 (working-capital loan) narrows the lists to what such
  a charge allows, and `time` narrows its calculations further.
  """
  @spec template(integer | nil, integer | nil) :: map
  def template(5 = _applies_to, time) do
    %{
      working_capital?: true,
      currencies: currencies(),
      calculations: Enums.calculation_options(working_capital_calculations(time)),
      applies_to: Enums.applies_to_options(),
      times: Enums.time_options(Enums.working_capital_times()),
      payment_modes: [Enums.payment_mode(0)]
    }
  end

  def template(_applies_to, _time) do
    accounts = ECBLedger.FinancialActivities.account_options()

    %{
      working_capital?: false,
      currencies: currencies(),
      calculations: Enums.calculation_options([1, 2, 3, 4, 5]),
      applies_to: Enums.applies_to_options(),
      times: Enums.time_options([1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]),
      payment_modes: Enums.payment_mode_options(),
      loan_calculations: Enums.calculation_options(Enums.loan_calculations()),
      loan_times: Enums.time_options(Enums.loan_times()),
      savings_calculations: Enums.calculation_options(Enums.savings_calculations()),
      savings_times: Enums.time_options([2, 3, 5, 6, 7, 11, 10, 16]),
      client_calculations: Enums.calculation_options(Enums.client_calculations()),
      client_times: Enums.time_options(Enums.client_times()),
      share_calculations: Enums.calculation_options(Enums.savings_calculations()),
      share_times: Enums.time_options(Enums.share_times()),
      fee_frequencies: Enums.fee_frequency_options(),
      income_or_liability_accounts: Map.take(accounts, [:income, :liability]),
      expense_accounts: Map.get(accounts, :expense, []),
      asset_accounts: Map.get(accounts, :asset, []),
      account_mapping: account_mapping()
    }
  end

  defp working_capital_calculations(nil), do: [1, 2]
  defp working_capital_calculations(time), do: Enums.working_capital_calculations(time)

  defp currencies, do: ECBOrg.Currencies.list().selected

  defp account_mapping do
    case ECBPlatform.Configuration.get("account-mapping-for-charge") do
      %{string_value: value} -> value
      _ -> nil
    end
  end

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.charge.id.invalid",
        "Charge with identifier #{id} does not exist",
        [id]
      )

  # --- internals ------------------------------------------------------------------------------

  defp base do
    from(c in "m_charge",
      join: oc in "m_organisation_currency",
      on: oc.code == c.currency_code,
      left_join: a in "acc_gl_account",
      on: a.id == c.income_or_liability_account_id,
      left_join: tg in "m_tax_group",
      on: tg.id == c.tax_group_id,
      left_join: pt in "m_payment_type",
      on: pt.id == c.payment_type_id,
      select: %{
        id: c.id,
        name: c.name,
        amount: c.amount,
        currency: %{
          code: c.currency_code,
          name: oc.name,
          decimal_places: oc.decimal_places,
          multiples_of: oc.currency_multiplesof,
          display_symbol: oc.display_symbol,
          name_code: oc.internationalized_name_code
        },
        applies_to: c.charge_applies_to_enum,
        time: c.charge_time_enum,
        payment_mode: c.charge_payment_mode_enum,
        calculation: c.charge_calculation_enum,
        penalty: c.is_penalty,
        active: c.is_active,
        free_withdrawal: c.is_free_withdrawal,
        free_withdrawal_frequency: c.free_withdrawal_charge_frequency,
        restart_frequency: c.restart_frequency,
        restart_frequency_enum: c.restart_frequency_enum,
        fee_on_day: c.fee_on_day,
        fee_on_month: c.fee_on_month,
        fee_interval: c.fee_interval,
        fee_frequency: c.fee_frequency,
        min_cap: c.min_cap,
        max_cap: c.max_cap,
        account: %{id: a.id, name: a.name, gl_code: a.gl_code},
        tax_group: %{id: tg.id, name: tg.name},
        payment_type_enabled: c.is_payment_type,
        payment_type: %{id: pt.id, name: pt.value}
      }
    )
  end

  defp finish(row) do
    row
    |> Map.update!(:account, &if(&1.id, do: &1, else: nil))
    |> Map.update!(:tax_group, &if(&1.id, do: &1, else: nil))
    |> Map.update!(:payment_type, &if(&1.id, do: &1, else: nil))
  end
end
