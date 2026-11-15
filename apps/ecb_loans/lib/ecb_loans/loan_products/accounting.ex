defmodule ECBLoans.LoanProducts.Accounting do
  @moduledoc """
  Maps a loan product to the general-ledger accounts its money goes to, following Fineract's
  `ProductToGLAccountMappingWritePlatformServiceImpl` and `LoanProductToGLAccountMappingHelper`.

  Each placeholder (loan portfolio, interest on loans, income from fees, ...) has a number and the account
  types the mapped account may be. A product with no accounting (rule 1) maps nothing; cash (2) maps the
  base set, and accrual (3 or 4) adds the receivables of interest, fees and penalties.
  """
  alias ECBLedger.ProductMappings
  alias ECBPlatform.{Json, Params}

  @asset 1
  @liability 2
  @income 4
  @expense 5

  # {request parameter, placeholder, the account types it may map to}, in the order Fineract maps them
  @cash [
    {"fundSourceAccountId", 1, [@asset, @liability]},
    {"loanPortfolioAccountId", 2, [@asset]},
    {"transfersInSuspenseAccountId", 10, [@asset]},
    {"interestOnLoanAccountId", 3, [@income]},
    {"incomeFromFeeAccountId", 4, [@income]},
    {"incomeFromPenaltyAccountId", 5, [@income]},
    {"incomeFromRecoveryAccountId", 12, [@income]},
    {"incomeFromChargeOffFeesAccountId", 15, [@income]},
    {"incomeFromChargeOffInterestAccountId", 14, [@income]},
    {"incomeFromChargeOffPenaltyAccountId", 18, [@income]},
    {"incomeFromGoodwillCreditInterestAccountId", 19, [@income]},
    {"incomeFromGoodwillCreditFeesAccountId", 20, [@income]},
    {"incomeFromGoodwillCreditPenaltyAccountId", 21, [@income]},
    {"writeOffAccountId", 6, [@expense]},
    {"goodwillCreditAccountId", 13, [@expense]},
    {"chargeOffExpenseAccountId", 16, [@expense]},
    {"chargeOffFraudExpenseAccountId", 17, [@expense]},
    {"overpaymentLiabilityAccountId", 11, [@liability]}
  ]

  @accrual_extra [
    {"receivableInterestAccountId", 7, [@asset]},
    {"receivableFeeAccountId", 8, [@asset]},
    {"receivablePenaltyAccountId", 9, [@asset]}
  ]

  @loan 1

  @doc "Maps a new product's accounts for accounting rule `rule` (the request has been checked)."
  @spec create!(integer, Params.t(), integer) :: :ok
  def create!(product_id, %Params{} = p, rule) when rule in [2, 3, 4] do
    accounts =
      if rule == 2, do: @cash, else: Enum.take(@cash, 3) ++ @accrual_extra ++ Enum.drop(@cash, 3)

    for {param, placeholder, types} <- accounts do
      ProductMappings.save_account!(
        @loan,
        product_id,
        param,
        Json.long(p, param),
        placeholder,
        types
      )
    end

    ProductMappings.save_payment_channels!(@loan, product_id, payment_pairs(p))

    ProductMappings.save_charge_accounts!(
      @loan,
      product_id,
      charge_pairs(p, "feeToIncomeAccountMappings"),
      false
    )

    ProductMappings.save_charge_accounts!(
      @loan,
      product_id,
      charge_pairs(p, "penaltyToIncomeAccountMappings"),
      true
    )

    :ok
  end

  def create!(_product_id, _p, _rule), do: :ok

  defp payment_pairs(p) do
    for mapping <- list(p, "paymentChannelToFundSourceMappings"),
        do:
          {Json.long(%Params{map: mapping}, "paymentTypeId"),
           Json.long(%Params{map: mapping}, "fundSourceAccountId")}
  end

  defp charge_pairs(p, name) do
    for mapping <- list(p, name),
        do:
          {Json.long(%Params{map: mapping}, "chargeId"),
           Json.long(%Params{map: mapping}, "incomeAccountId")}
  end

  defp list(p, name) do
    case Params.value(p, name) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end
end
