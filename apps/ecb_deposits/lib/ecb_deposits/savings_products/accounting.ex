defmodule ECBDeposits.SavingsProducts.Accounting do
  @moduledoc """
  Maps a savings product to the general-ledger accounts its money goes to, following Fineract's
  `ProductToGLAccountMappingWritePlatformServiceImpl` and `SavingsProductToGLAccountMappingHelper`.

  Each placeholder (savings control, interest on savings, income from fees, ...) has a number and an account
  type the mapped account must be. A product with no accounting (rule 1) maps nothing; cash (2) and periodic
  accrual (3) map the same base set, accrual adding the receivables and the interest payable.
  """
  alias ECBLedger.ProductMappings
  alias ECBPlatform.{Json, Params, Validation}

  @saving 2

  # {request parameter, placeholder, account type}
  @base [
    {"savingsReferenceAccountId", 1, :asset},
    {"overdraftPortfolioControlId", 11, :asset},
    {"incomeFromFeeAccountId", 4, :income},
    {"incomeFromPenaltyAccountId", 5, :income},
    {"incomeFromInterestId", 12, :income},
    {"interestOnSavingsAccountId", 3, :expense},
    {"writeOffAccountId", 13, :expense},
    {"savingsControlAccountId", 2, :liability},
    {"transfersInSuspenseAccountId", 10, :liability}
  ]

  @accrual [
    {"interestReceivableAccountId", 18, :asset},
    {"feesReceivableAccountId", 15, :asset},
    {"penaltiesReceivableAccountId", 16, :asset},
    {"interestPayableAccountId", 17, :liability}
  ]

  @escheat {"escheatLiabilityId", 14, :liability}

  # the names a placeholder is called when its mapping is missing
  @names %{
    1 => "SAVINGS REFERENCE",
    11 => "OVERDRAFT PORTFOLIO CONTROL",
    4 => "INCOME FROM FEES",
    5 => "INCOME FROM PENALTIES",
    12 => "INCOME FROM INTEREST",
    3 => "INTEREST ON SAVINGS",
    13 => "LOSSES WRITTEN OFF",
    2 => "SAVINGS CONTROL",
    10 => "TRANSFERS SUSPENSE",
    15 => "FEES RECEIVABLE",
    16 => "PENALTIES RECEIVABLE",
    17 => "INTEREST PAYABLE",
    18 => "INTEREST RECEIVABLE"
  }

  # --- create ---------------------------------------------------------------------------------

  @doc "Maps a new product's accounts for accounting rule `rule` (the request has been checked)."
  @spec create!(integer, Params.t(), integer) :: :ok
  def create!(product_id, %Params{} = p, rule) when rule in [2, 3] do
    save_base!(product_id, p)

    if rule == 3 do
      for {param, placeholder, type} <- @accrual,
          do: save!(product_id, p, param, placeholder, type)
    end

    :ok
  end

  def create!(_product_id, _p, _rule), do: :ok

  defp save_base!(product_id, p) do
    for {param, placeholder, type} <- @base, do: save!(product_id, p, param, placeholder, type)

    if Params.boolean(p, "isDormancyTrackingActive") == true do
      {param, placeholder, type} = @escheat
      save!(product_id, p, param, placeholder, type)
    end

    ProductMappings.save_payment_channels!(@saving, product_id, payment_pairs(p))

    ProductMappings.save_charge_accounts!(
      @saving,
      product_id,
      charge_pairs(p, "feeToIncomeAccountMappings"),
      false
    )

    ProductMappings.save_charge_accounts!(
      @saving,
      product_id,
      charge_pairs(p, "penaltyToIncomeAccountMappings"),
      true
    )
  end

  defp save!(product_id, p, param, placeholder, type) do
    ProductMappings.save_account!(
      @saving,
      product_id,
      param,
      Json.long(p, param),
      placeholder,
      [ProductMappings.account_type(type)]
    )
  end

  # --- update ---------------------------------------------------------------------------------

  @doc """
  Brings a product's mappings in line with an update. A changed accounting rule starts the mappings over
  (after checking the request names every account the new rule needs); otherwise the accounts named change
  one by one. Answers what to add to the response's `changes`.
  """
  @spec update!(integer, Params.t(), integer, boolean) :: map
  def update!(product_id, %Params{} = p, rule, true = _rule_changed) do
    check_rule_change!(p, rule)
    ProductMappings.delete_all!(@saving, product_id)
    create!(product_id, p, rule)
    new_mapping_changes(p, rule)
  end

  def update!(product_id, %Params{} = p, rule, false = _rule_changed) do
    changes = merge_changes(product_id, p, rule, %{})

    changes
    |> payment_channel_changes(product_id, p)
    |> charge_changes(product_id, p)
  end

  # the full set of accounts a new rule needs; Fineract checks only some of them for accruals
  defp check_rule_change!(p, rule) do
    v = Validation.new("savingsproduct")

    v =
      v
      |> Validation.param("accountingRule", rule)
      |> Validation.not_null()
      |> Validation.in_range(1, 3)

    v = if rule == 2, do: rule_accounts(v, p, true), else: v
    v = if rule in [3, 4], do: accrual_accounts(v, p), else: v
    Validation.raise_if_errors!(v)
  end

  defp rule_accounts(v, p, dormancy?) do
    ~w(savingsControlAccountId savingsReferenceAccountId transfersInSuspenseAccountId
       interestOnSavingsAccountId incomeFromFeeAccountId incomeFromPenaltyAccountId)
    |> required(v, p)
    |> then(fn v ->
      if dormancy? and Params.boolean(p, "isDormancyTrackingActive") == true,
        do: required(["escheatLiabilityId"], v, p),
        else: v
    end)
    |> then(
      &required(~w(overdraftPortfolioControlId incomeFromInterestId writeOffAccountId), &1, p)
    )
  end

  defp accrual_accounts(v, p),
    do:
      required(
        ~w(feesReceivableAccountId penaltiesReceivableAccountId interestPayableAccountId),
        v,
        p
      )

  defp required(keys, v, p) do
    Enum.reduce(keys, v, fn key, v ->
      v
      |> Validation.param(key, Json.long(p, key))
      |> Validation.not_null()
      |> Validation.greater_than_zero()
    end)
  end

  # what the response shows for a product whose mappings were started over: the accounts as named
  defp new_mapping_changes(p, rule) do
    keys =
      case rule do
        2 -> Enum.map(@base, &elem(&1, 0))
        3 -> Enum.map(@base ++ tl(@accrual), &elem(&1, 0))
        _ -> []
      end

    Map.new(keys, fn key -> {key, Json.long(p, key)} end)
  end

  defp merge_changes(_product_id, _p, rule, changes) when rule not in [2, 3], do: changes

  defp merge_changes(product_id, p, rule, changes) do
    accounts = if rule == 3, do: @base ++ @accrual, else: @base

    changes =
      Enum.reduce(accounts, changes, fn {param, placeholder, type}, changes ->
        ProductMappings.merge_account!(
          @saving,
          product_id,
          param,
          Json.long(p, param),
          placeholder,
          Map.fetch!(@names, placeholder),
          [ProductMappings.account_type(type)],
          changes
        )
      end)

    {param, placeholder, type} = @escheat

    ProductMappings.create_or_merge_account!(
      @saving,
      product_id,
      param,
      Json.long(p, param),
      placeholder,
      [ProductMappings.account_type(type)],
      changes
    )
  end

  defp payment_channel_changes(changes, product_id, p) do
    if is_list(Params.value(p, "paymentChannelToFundSourceMappings")) do
      ProductMappings.update_payment_channels!(@saving, product_id, payment_pairs(p))

      Map.put(
        changes,
        "paymentChannelToFundSourceMappings",
        fragment(p, "paymentChannelToFundSourceMappings")
      )
    else
      changes
    end
  end

  defp charge_changes(changes, product_id, p) do
    Enum.reduce(
      [{"feeToIncomeAccountMappings", false}, {"penaltyToIncomeAccountMappings", true}],
      changes,
      fn
        {name, penalty?}, changes ->
          if is_list(Params.value(p, name)) do
            ProductMappings.update_charge_accounts!(
              @saving,
              product_id,
              charge_pairs(p, name),
              penalty?
            )

            Map.put(changes, name, fragment(p, name))
          else
            changes
          end
      end
    )
  end

  # a part of the request as the text it was sent in (Fineract's `jsonFragment`)
  defp fragment(p, name), do: Params.fragment(p, name)

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
