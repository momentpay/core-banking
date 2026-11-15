defmodule ECBLoans.LoanProducts do
  @moduledoc """
  Loan products (`m_product_loan`), the read side, following Fineract's `LoanProductReadPlatformServiceImpl`.

  A loan product is what loans are made from: the currency, the amounts and number of repayments allowed, how
  often they fall due, the interest and how it is worked out, the grace periods, the order a payment is applied
  to what is owed, the charges it carries and the ledger accounts its money goes to.

  Only the core of Fineract's loan products is built so far: a cumulative schedule with a flat or declining
  interest, no interest recalculation, one disbursement and no floating rates, borrower cycles, variable
  installments, guarantees, rates, delinquency, advanced payment allocation, down payments, capitalised income
  or buy-down fees. What the product does not yet support is shown with the values Fineract shows for a product
  without it. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.ProductMappings
  alias ECBLoans.LoanEnums
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @static Path.join(:code.priv_dir(:ecb_loans), "loan_product_static.json")
          |> File.read!()
          |> Jason.decode!()

  @external_resource Path.join(:code.priv_dir(:ecb_loans), "loan_product_static.json")

  @doc "What a product shows that does not depend on the product (flags that are off, lists of choices)."
  @spec static() :: map
  def static, do: @static

  @doc "The transaction-processing strategies, as `%{code, name}`."
  @spec strategies() :: [map]
  def strategies, do: @static["strategies"]

  @doc "The name of a strategy by its code, or `nil`."
  @spec strategy_name(String.t()) :: String.t() | nil
  def strategy_name(code) do
    case Enum.find(strategies(), &(&1["code"] == code)) do
      nil -> nil
      strategy -> strategy["name"]
    end
  end

  @doc "Every loan product, by id."
  @spec list() :: [map]
  def list, do: base() |> order_by([lp], lp.id) |> TenantRepo.all() |> Enum.map(&finish/1)

  @doc "One loan product, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([lp], lp.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "Like `get/1` but raises."
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
        "error.msg.loanproduct.id.invalid",
        "Loan product with identifier #{id} does not exist",
        [id]
      )

  defp base do
    from(lp in "m_product_loan",
      join: curr in "m_currency",
      on: curr.code == lp.currency_code,
      left_join: f in "m_fund",
      on: f.id == lp.fund_id,
      select: %{
        id: lp.id,
        name: lp.name,
        short_name: lp.short_name,
        description: lp.description,
        fund_id: lp.fund_id,
        fund_name: f.name,
        external_id: lp.external_id,
        include_in_borrower_cycle: lp.include_in_borrower_cycle,
        use_borrower_cycle: lp.use_borrower_cycle,
        currency: %{
          code: lp.currency_code,
          name: curr.name,
          decimal_places: lp.currency_digits,
          multiples_of: lp.currency_multiplesof,
          display_symbol: curr.display_symbol,
          name_code: curr.internationalized_name_code
        },
        principal: lp.principal_amount,
        min_principal: lp.min_principal_amount,
        max_principal: lp.max_principal_amount,
        number_of_repayments: lp.number_of_repayments,
        min_number_of_repayments: lp.min_number_of_repayments,
        max_number_of_repayments: lp.max_number_of_repayments,
        repay_every: lp.repay_every,
        repayment_frequency_id: lp.repayment_period_frequency_enum,
        interest_rate: lp.nominal_interest_rate_per_period,
        min_interest_rate: lp.min_nominal_interest_rate_per_period,
        max_interest_rate: lp.max_nominal_interest_rate_per_period,
        interest_frequency_id: lp.interest_period_frequency_enum,
        annual_interest_rate: lp.annual_nominal_interest_rate,
        amortization_id: lp.amortization_method_enum,
        interest_type_id: lp.interest_method_enum,
        interest_period_id: lp.interest_calculated_in_period_enum,
        allow_partial_period: lp.allow_partial_period_interest_calcualtion,
        in_arrears_tolerance: lp.arrearstolerance_amount,
        strategy_code: lp.loan_transaction_strategy_code,
        strategy_name: lp.loan_transaction_strategy_name,
        grace_on_principal: lp.grace_on_principal_periods,
        grace_on_interest: lp.grace_on_interest_periods,
        grace_on_interest_charged: lp.grace_interest_free_periods,
        grace_on_arrears_ageing: lp.grace_on_arrears_ageing,
        overdue_days_for_npa: lp.overdue_days_for_npa,
        days_in_month_id: lp.days_in_month_enum,
        days_in_year_id: lp.days_in_year_enum,
        min_days_between_disbursal_and_first_repayment:
          lp.min_days_between_disbursal_and_first_repayment,
        can_define_installment_amount: lp.can_define_fixed_emi_amount,
        installment_amount_in_multiples_of: lp.installment_amount_in_multiples_of,
        accounting_id: lp.accounting_type,
        can_use_for_topup: lp.can_use_for_topup,
        enable_accrual_activity_posting: lp.enable_accrual_activity_posting,
        principal_threshold_for_last_installment: lp.principal_threshold_for_last_installment,
        hold_guarantee_funds: lp.hold_guarantee_funds,
        account_moves_out_of_npa: lp.account_moves_out_of_npa_only_on_arrears_completion,
        due_days_for_repayment_event: lp.due_days_for_repayment_event,
        overdue_days_for_repayment_event: lp.overdue_days_for_repayment_event,
        repayment_start_id: lp.repayment_start_date_type_enum,
        sync_expected_with_disbursement_date: lp.sync_expected_with_disbursement_date,
        start_date: lp.start_date,
        close_date: lp.close_date
      }
    )
  end

  defp finish(row) do
    row
    |> Map.put(
      :repayment_frequency,
      LoanEnums.option(:repayment_frequency, row.repayment_frequency_id)
    )
    |> Map.put(
      :interest_frequency,
      LoanEnums.option(:interest_frequency, row.interest_frequency_id)
    )
    |> Map.put(:amortization, LoanEnums.option(:amortization, row.amortization_id))
    |> Map.put(:interest_type, LoanEnums.option(:interest_type, row.interest_type_id))
    |> Map.put(:interest_period, LoanEnums.option(:interest_period, row.interest_period_id))
    |> Map.put(:days_in_month, LoanEnums.option(:days_in_month, row.days_in_month_id))
    |> Map.put(:days_in_year, LoanEnums.option(:days_in_year, row.days_in_year_id))
    |> Map.put(:repayment_start, LoanEnums.option(:repayment_start, row.repayment_start_id))
    |> Map.put(:accounting, LoanEnums.option(:accounting, row.accounting_id))
    |> Map.update!(:installment_amount_in_multiples_of, &whole/1)
  end

  defp whole(nil), do: nil
  defp whole(%Decimal{} = d), do: Decimal.to_integer(d)
  defp whole(n), do: n

  # --- what hangs off a product -----------------------------------------------------------------

  @doc "The ids of the charges a product carries, ascending."
  @spec charge_ids(integer) :: [integer]
  def charge_ids(product_id) do
    TenantRepo.all(
      from(c in "m_product_loan_charge",
        where: c.product_loan_id == ^product_id,
        order_by: c.charge_id,
        select: c.charge_id
      )
    )
  end

  @doc "Replaces the charges a product carries with those in `charge_ids` (a charge named twice breaks the table's key)."
  @spec set_charges!(integer, [integer]) :: :ok
  def set_charges!(product_id, charge_ids) do
    TenantRepo.delete_all(
      from(c in "m_product_loan_charge", where: c.product_loan_id == ^product_id)
    )

    TenantRepo.insert_all(
      "m_product_loan_charge",
      Enum.map(charge_ids, &%{product_loan_id: product_id, charge_id: &1})
    )

    :ok
  end

  @doc "Whether a product keeps its accounts in the ledger."
  @spec accounting?(map) :: boolean
  def accounting?(%{accounting_id: id}), do: id not in [nil, 1]

  # the placeholders each rule knows, by number, with the name a read shows them under
  @cash %{
    1 => "fundSourceAccount",
    2 => "loanPortfolioAccount",
    3 => "interestOnLoanAccount",
    4 => "incomeFromFeeAccount",
    5 => "incomeFromPenaltyAccount",
    6 => "writeOffAccount",
    10 => "transfersInSuspenseAccount",
    11 => "overpaymentLiabilityAccount",
    12 => "incomeFromRecoveryAccount",
    13 => "goodwillCreditAccount",
    14 => "incomeFromChargeOffInterestAccount",
    15 => "incomeFromChargeOffFeesAccount",
    16 => "chargeOffExpenseAccount",
    17 => "chargeOffFraudExpenseAccount",
    18 => "incomeFromChargeOffPenaltyAccount",
    19 => "incomeFromGoodwillCreditInterestAccount",
    20 => "incomeFromGoodwillCreditFeesAccount",
    21 => "incomeFromGoodwillCreditPenaltyAccount"
  }

  @accrual Map.merge(@cash, %{
             7 => "receivableInterestAccount",
             8 => "receivableFeeAccount",
             9 => "receivablePenaltyAccount"
           })

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
  def accounting_details(%{id: id, accounting_id: rule}) do
    loan = ProductMappings.loan()
    names = if rule == 2, do: @cash, else: @accrual

    %{
      mappings:
        for(
          row <- ProductMappings.regular(loan, id),
          name = Map.get(names, row.placeholder),
          do: %{name: name, account: row.account}
        ),
      payment_types: none_if_empty(ProductMappings.payment_types(loan, id)),
      fees: none_if_empty(ProductMappings.charges(loan, id, false)),
      penalties: none_if_empty(ProductMappings.charges(loan, id, true))
    }
  end

  defp none_if_empty([]), do: nil
  defp none_if_empty(list), do: list
end
