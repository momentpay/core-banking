defmodule ECBCatalog.Charges.Enums do
  @moduledoc """
  The fixed vocabularies of charges, as Fineract names them: what a charge applies to (loan, savings,
  client, shares, working-capital loan), when it falls due, how it is worked out, and how it is paid. Each
  value is an `%{id, code, value}` option; which times and calculations suit which product is here too.
  """

  @applies_to [
    {1, "chargeAppliesTo.loan", "Loan"},
    {2, "chargeAppliesTo.savings", "Savings"},
    {3, "chargeAppliesTo.client", "Client"},
    {4, "chargeAppliesTo.shares", "Shares"},
    {5, "chargeAppliesTo.workingCapitalLoan", "Working Capital Loan"}
  ]

  @times [
    {1, "chargeTimeType.disbursement", "Disbursement"},
    {2, "chargeTimeType.specifiedDueDate", "Specified due date"},
    {3, "chargeTimeType.savingsActivation", "Savings Activation"},
    {4, "chargeTimeType.savingsClosure", "Savings Closure"},
    {5, "chargeTimeType.withdrawalFee", "Withdrawal Fee"},
    {6, "chargeTimeType.annualFee", "Annual Fee"},
    {7, "chargeTimeType.monthlyFee", "Monthly Fee"},
    {8, "chargeTimeType.instalmentFee", "Installment Fee"},
    {9, "chargeTimeType.overdueInstallment", "Overdue Fees"},
    {10, "chargeTimeType.overdraftFee", "Overdraft Fee"},
    {11, "chargeTimeType.weeklyFee", "Weekly Fee"},
    {12, "chargeTimeType.tranchedisbursement", "Tranche Disbursement"},
    {13, "chargeTimeType.activation", "Share Account Activate"},
    {14, "chargeTimeType.sharespurchase", "Share Purchase"},
    {15, "chargeTimeType.sharesredeem", "Share Redeem"},
    {16, "chargeTimeType.savingsNoActivityFee", "Saving No Activity Fee"}
  ]

  @calculations [
    {1, "chargeCalculationType.flat", "Flat"},
    {2, "chargeCalculationType.percent.of.amount", "% Amount"},
    {3, "chargeCalculationType.percent.of.amount.and.interest", "% Loan Amount + Interest"},
    {4, "chargeCalculationType.percent.of.interest", "% Interest"},
    {5, "chargeCalculationType.percent.of.disbursement.amount", "% Disbursement Amount"}
  ]

  @payment_modes [
    {0, "chargepaymentmode.regular", "Regular"},
    {1, "chargepaymentmode.accounttransfer", "Account transfer"}
  ]

  # how often a fee repeats; Fineract's own list also holds an "Invalid" entry
  @frequencies [
    {0, "periodFrequencyType.days", "Days"},
    {1, "periodFrequencyType.weeks", "Weeks"},
    {2, "periodFrequencyType.months", "Months"},
    {3, "periodFrequencyType.years", "Years"}
  ]

  # --- what a charge may be, by product -------------------------------------------------------

  @doc "The kinds of thing a charge applies to (their ids)."
  def applies_to_ids, do: for({id, _, _} <- @applies_to, do: id)

  @doc "The times a loan charge may fall due (their ids), in Fineract's order."
  def loan_times, do: [1, 2, 8, 9, 12]

  @doc "The times a savings charge may fall due."
  def savings_times, do: [2, 3, 4, 5, 6, 7, 10, 11, 16]

  @doc "The times a client charge may fall due."
  def client_times, do: [2]

  @doc "The times a share charge may fall due."
  def share_times, do: [13, 14, 15]

  @doc "The times a working-capital loan charge may fall due."
  def working_capital_times, do: [1, 2]

  @doc "Every time of the loan, savings, client and share lists joined, repeats and all, as Fineract does."
  def all_times, do: loan_times() ++ savings_times() ++ client_times() ++ share_times()

  @doc "The calculations a loan charge may use."
  def loan_calculations, do: [1, 2, 3, 4, 5]

  @doc "The calculations a savings or share charge may use."
  def savings_calculations, do: [1, 2]

  @doc "The calculations a client charge may use."
  def client_calculations, do: [1]

  @doc "The calculations a charge that falls due at tranche disbursement may use."
  def tranche_calculations, do: [1, 5]

  @doc "The calculations a working-capital charge may use for a time it falls due."
  def working_capital_calculations(1), do: [1, 2]
  def working_capital_calculations(2), do: [1]
  def working_capital_calculations(_time), do: []

  @doc "The payment modes a charge may use."
  def payment_modes, do: [0, 1]

  # --- options --------------------------------------------------------------------------------

  @doc "The option for a charge's applies-to id, or `nil`."
  def applies_to(id), do: find(@applies_to, id)

  @doc "The option for a due time id."
  def time(id), do: find(@times, id)

  @doc "The option for a calculation id."
  def calculation(id), do: find(@calculations, id)

  @doc "The option for a payment mode id."
  def payment_mode(id), do: find(@payment_modes, id)

  @doc "The option for a fee frequency, coded the way a charge shows it (`feeFrequencyperiodFrequencyType.weeks`)."
  def fee_frequency(id) do
    case List.keyfind(@frequencies, id, 0) do
      {id, code, value} -> %{id: id, code: "feeFrequency" <> code, value: value}
      nil -> %{id: 5, code: "periodFrequencyType.invalid", value: "Invalid"}
    end
  end

  @doc "All kinds of applies-to as options."
  def applies_to_options, do: options(@applies_to, applies_to_ids())

  @doc "The due times for `ids` as options, in that order."
  def time_options(ids), do: Enum.map(ids, &time/1)

  @doc "The calculations for `ids` as options."
  def calculation_options(ids), do: Enum.map(ids, &calculation/1)

  @doc "The payment modes as options."
  def payment_mode_options, do: Enum.map(payment_modes(), &payment_mode/1)

  @doc "The fee frequencies a form offers, coded as Fineract codes them for a template, ending with its \"Invalid\" entry."
  def fee_frequency_options do
    for({id, code, value} <- @frequencies, do: %{id: id, code: "frequency" <> code, value: value}) ++
      [%{id: 5, code: "periodFrequencyType.invalid", value: "Invalid"}]
  end

  defp find(list, id) do
    case List.keyfind(list, id, 0) do
      {id, code, value} -> %{id: id, code: code, value: value}
      nil -> nil
    end
  end

  defp options(list, ids), do: for(id <- ids, do: find(list, id))
end
