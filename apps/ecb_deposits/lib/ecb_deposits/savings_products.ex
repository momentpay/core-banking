defmodule ECBDeposits.SavingsProducts do
  @moduledoc """
  Savings products (`m_savings_product`), the read side, following Fineract's
  `SavingsProductReadPlatformServiceImpl`.

  A savings product is the template its accounts copy: the interest it pays and how it is compounded and
  posted, overdraft and balance rules, charges, dormancy, tax withholding, and the general-ledger accounts
  its money goes to. The same table also holds fixed and recurring deposit products (by `deposit_type_enum`);
  only savings products (type 100) are seen here. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.SavingsEnums
  alias ECBLedger.ProductMappings
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @savings_deposit 100

  @doc "The deposit type of a savings product."
  def deposit_type, do: @savings_deposit

  @doc "Every savings product, by id."
  @spec list() :: [map]
  def list, do: list(@savings_deposit)

  @doc "Every product of a deposit type (100 savings, 200 fixed, 300 recurring), by id."
  @spec list(integer) :: [map]
  def list(type),
    do: type |> base() |> order_by([sp], sp.id) |> TenantRepo.all() |> Enum.map(&finish/1)

  @doc "`%{id, name}` of every savings product, by id (for choosing one)."
  @spec lookup() :: [map]
  def lookup do
    from(sp in "m_savings_product",
      where: sp.deposit_type_enum == ^@savings_deposit,
      order_by: sp.id,
      select: %{id: sp.id, name: sp.name}
    )
    |> TenantRepo.all()
  end

  @doc "One savings product, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id), do: get(@savings_deposit, id)

  @doc "One product of a deposit type, or `{:error, ResourceNotFound}` (that of savings products)."
  @spec get(integer, integer) :: {:ok, map} | {:error, Exception.t()}
  def get(type, id) do
    case type |> base() |> where([sp], sp.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "Like `get/1` but raises the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, product} -> product
      {:error, error} -> raise error
    end
  end

  @doc "The not-found error."
  @spec not_found(integer) :: Exception.t()
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.savingproduct.id.invalid",
        "Saving product with identifier #{id} does not exist",
        [id]
      )

  defp base(type) do
    from(sp in "m_savings_product",
      join: curr in "m_currency",
      on: curr.code == sp.currency_code,
      left_join: tg in "m_tax_group",
      on: tg.id == sp.tax_group_id,
      where: sp.deposit_type_enum == ^type,
      select: %{
        id: sp.id,
        name: sp.name,
        short_name: sp.short_name,
        description: sp.description,
        currency: %{
          code: sp.currency_code,
          name: curr.name,
          decimal_places: sp.currency_digits,
          multiples_of: sp.currency_multiplesof,
          display_symbol: curr.display_symbol,
          name_code: curr.internationalized_name_code
        },
        nominal_annual_interest_rate: sp.nominal_annual_interest_rate,
        compounding_id: sp.interest_compounding_period_enum,
        posting_id: sp.interest_posting_period_enum,
        calculation_id: sp.interest_calculation_type_enum,
        days_in_year_id: sp.interest_calculation_days_in_year_type_enum,
        min_required_opening_balance: sp.min_required_opening_balance,
        lockin_period_frequency: sp.lockin_period_frequency,
        lockin_type_id: sp.lockin_period_frequency_enum,
        withdrawal_fee_for_transfers: sp.withdrawal_fee_for_transfer,
        allow_overdraft: sp.allow_overdraft,
        overdraft_limit: sp.overdraft_limit,
        nominal_annual_interest_rate_overdraft: sp.nominal_annual_interest_rate_overdraft,
        min_overdraft_for_interest_calculation: sp.min_overdraft_for_interest_calculation,
        min_required_balance: sp.min_required_balance,
        enforce_min_required_balance: sp.enforce_min_required_balance,
        max_allowed_lien_limit: sp.max_allowed_lien_limit,
        lien_allowed: sp.is_lien_allowed,
        min_balance_for_interest_calculation: sp.min_balance_for_interest_calculation,
        accounting_id: sp.accounting_type,
        withhold_tax: sp.withhold_tax,
        tax_group: %{id: tg.id, name: tg.name},
        dormancy_tracking_active: sp.is_dormancy_tracking_active,
        days_to_inactive: sp.days_to_inactive,
        days_to_dormancy: sp.days_to_dormancy,
        days_to_escheat: sp.days_to_escheat
      }
    )
  end

  defp finish(row) do
    row
    |> Map.put(:compounding, SavingsEnums.compounding(row.compounding_id))
    |> Map.put(:posting, SavingsEnums.posting(row.posting_id))
    |> Map.put(:calculation, SavingsEnums.calculation(row.calculation_id))
    |> Map.put(:days_in_year, SavingsEnums.days_in_year(row.days_in_year_id))
    |> Map.put(:lockin_type, SavingsEnums.lockin(row.lockin_type_id))
    |> Map.put(:accounting, SavingsEnums.accounting(row.accounting_id))
    |> Map.update!(:lockin_period_frequency, &whole/1)
    |> Map.put(:tax_group, if(row.tax_group.id, do: row.tax_group))
  end

  @doc false
  def whole(nil), do: nil
  def whole(%Decimal{} = d), do: Decimal.to_integer(d)
  def whole(n), do: n

  # --- what hangs off a product -----------------------------------------------------------------

  @doc "Whether a product keeps its accounts in the ledger (any rule but none)."
  @spec accounting?(map) :: boolean
  def accounting?(%{accounting_id: id}), do: id not in [nil, 1]

  @doc """
  The accounting a product has: the mapped accounts by what they are for, the fund source of each payment
  type, and the income account of each fee and penalty (an empty list is `nil`).
  """
  @spec accounting_details(map) :: %{
          mappings: [map],
          payment_types: [map] | nil,
          fees: [map] | nil,
          penalties: [map] | nil
        }
  def accounting_details(%{id: id, accounting_id: accounting_id}) do
    saving = ProductMappings.saving()

    %{
      mappings: accounting_id |> accounts_for() |> mapped(ProductMappings.regular(saving, id)),
      payment_types: none_if_empty(ProductMappings.payment_types(saving, id)),
      fees: none_if_empty(ProductMappings.charges(saving, id, false)),
      penalties: none_if_empty(ProductMappings.charges(saving, id, true))
    }
  end

  defp none_if_empty([]), do: nil
  defp none_if_empty(list), do: list

  # the placeholders each rule knows, by number, with the name a read shows them under
  @cash %{
    1 => "savingsReferenceAccount",
    2 => "savingsControlAccount",
    3 => "interestOnSavingsAccount",
    4 => "incomeFromFeeAccount",
    5 => "incomeFromPenaltyAccount",
    10 => "transfersInSuspenseAccount",
    11 => "overdraftPortfolioControl",
    12 => "incomeFromInterest",
    13 => "writeOffAccount",
    14 => "escheatLiabilityAccount"
  }

  @accrual Map.merge(@cash, %{
             15 => "feeReceivableAccount",
             16 => "penaltyReceivableAccount",
             17 => "interestPayableAccount",
             18 => "interestReceivableAccount"
           })

  defp accounts_for(2), do: @cash
  defp accounts_for(3), do: @accrual
  defp accounts_for(_), do: %{}

  defp mapped(names, rows) do
    for row <- rows,
        name = Map.get(names, row.placeholder),
        do: %{name: name, account: row.account}
  end

  # --- charges and tax groups of a product ---------------------------------------------------------

  @doc "Replaces the charges a product carries with those in `charge_ids`."
  @spec set_charges!(integer, [integer]) :: :ok
  def set_charges!(product_id, charge_ids) do
    TenantRepo.delete_all(
      from(c in "m_savings_product_charge", where: c.savings_product_id == ^product_id)
    )

    TenantRepo.insert_all(
      "m_savings_product_charge",
      Enum.map(Enum.uniq(charge_ids), &%{savings_product_id: product_id, charge_id: &1})
    )

    :ok
  end

  @doc "The ids of the charges a product carries, ascending."
  @spec charge_ids(integer) :: [integer]
  def charge_ids(product_id) do
    TenantRepo.all(
      from(c in "m_savings_product_charge",
        where: c.savings_product_id == ^product_id,
        order_by: c.charge_id,
        select: c.charge_id
      )
    )
  end
end
