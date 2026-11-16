defmodule ECBLoans.Schedule.Charges do
  @moduledoc """
  The fees and penalties of a loan in its repayment schedule, after Fineract's `LoanCharge` and the schedule
  generator's handling of charges.

  A charge says when it falls due and how it is worked out:

    * at disbursement (time 1): once, in the disbursement row, flat or a percentage of the loan amount;
    * a specified due date (time 2): once, in the installment whose period holds the date (the first
      installment's period starts on the day the loan is paid out, the others the day after their start), flat or
      a percentage of the loan amount, of the loan amount and all its interest, or of all its interest;
    * on every installment (time 8): in each installment, flat or a percentage of that installment's principal,
      of its principal and interest, or of its interest.

  Percentages are rounded to the currency. A charge of a penalty goes to the penalty column, a fee to the fee
  column. `apply_to/2` puts them into a schedule and says what each came to.
  """
  alias ECBMoney

  @disbursement 1
  @specified_due_date 2
  @installment 8

  @flat 1
  @percent_of_amount 2
  @percent_of_amount_and_interest 3
  @percent_of_interest 4

  @doc """
  Puts the charges of `terms` into `schedule`. Returns `{schedule, details}`: the schedule with its fee and
  penalty columns and totals filled in, and for each charge (in the order given) `%{charge:, total:,
  applied_to:, installments: [{number, money}]}`.
  """
  @spec apply_to(map, map) :: {map, [map]}
  def apply_to(schedule, %{charges: charges}) when charges in [nil, []],
    do:
      {schedule
       |> Map.put_new(:disbursement_fees, nil)
       |> Map.put_new(:disbursement_fees_shown, nil), []}

  def apply_to(schedule, %{charges: charges}) do
    details = Enum.map(charges, &detail(&1, schedule))
    {with_amounts(schedule, details), details}
  end

  def apply_to(schedule, _terms), do: {schedule, []}

  # --- what a charge comes to ----------------------------------------------------------------------------

  defp detail(%{time: @disbursement} = charge, schedule) do
    amount = money(charge, loan_base(charge, schedule))

    %{
      charge: charge,
      total: amount,
      applied_to: applied_to(charge, schedule),
      installments: [],
      at_disbursement: amount,
      shown: if(charge.calc == @flat, do: charge.amount, else: ECBMoney.amount(amount))
    }
  end

  defp detail(%{time: @specified_due_date} = charge, schedule) do
    case period_holding(schedule.periods, charge.due_date) do
      nil ->
        none(charge, schedule)

      period ->
        amount = money(charge, loan_base(charge, schedule))

        %{
          charge: charge,
          total: amount,
          applied_to: applied_to(charge, schedule),
          installments: [{period.number, amount}]
        }
    end
  end

  defp detail(%{time: @installment} = charge, schedule) do
    installments =
      for p <- schedule.periods do
        base =
          case charge.calc do
            @percent_of_amount -> p.principal
            @percent_of_amount_and_interest -> ECBMoney.plus(p.principal, p.interest)
            @percent_of_interest -> p.interest
            _ -> p.principal
          end

        {p.number, money(charge, base)}
      end

    total =
      Enum.reduce(installments, zero(schedule), fn {_n, m}, sum -> ECBMoney.plus(sum, m) end)

    %{
      charge: charge,
      total: total,
      applied_to: applied_to(charge, schedule),
      installments: installments
    }
  end

  defp none(charge, schedule),
    do: %{
      charge: charge,
      total: zero(schedule),
      applied_to: applied_to(charge, schedule),
      installments: []
    }

  # the amount of a charge worked out on `base` (a flat charge ignores it)
  defp money(%{calc: @flat, amount: amount}, base),
    do: ECBMoney.new(ECBMoney.currency(base), amount, base.context)

  defp money(%{amount: pct}, base), do: ECBMoney.percentage_of(base, pct)

  # what a charge on the loan as a whole is a percentage of
  defp loan_base(%{calc: @percent_of_amount_and_interest}, schedule),
    do: ECBMoney.plus(schedule.principal, schedule.total_interest)

  defp loan_base(%{calc: @percent_of_interest}, schedule), do: schedule.total_interest
  defp loan_base(_charge, schedule), do: schedule.principal

  # what a percentage of the charge was taken of (nothing for a flat charge)
  defp applied_to(%{calc: @flat}, _schedule), do: nil
  defp applied_to(%{calc: @percent_of_amount}, schedule), do: ECBMoney.amount(schedule.principal)

  defp applied_to(%{calc: @percent_of_amount_and_interest}, schedule),
    do: ECBMoney.amount(ECBMoney.plus(schedule.principal, schedule.total_interest))

  defp applied_to(%{calc: @percent_of_interest}, schedule),
    do: ECBMoney.amount(schedule.total_interest)

  defp period_holding(periods, date) do
    first = periods |> Enum.map(& &1.number) |> Enum.min(fn -> nil end)

    Enum.find(periods, fn p ->
      after_start? =
        if p.number == first,
          do: Date.compare(date, p.from) != :lt,
          else: Date.compare(date, p.from) == :gt

      after_start? and Date.compare(date, p.due) != :gt
    end)
  end

  # --- into the schedule ------------------------------------------------------------------------------------

  defp with_amounts(schedule, details) do
    zero = zero(schedule)

    fees = sum_for(details, false, zero)
    penalties = sum_for(details, true, zero)

    at_disbursement =
      details |> Enum.map(&Map.get(&1, :at_disbursement)) |> Enum.reject(&is_nil/1)

    periods =
      Enum.map(schedule.periods, fn p ->
        fee = in_period(details, p.number, false, zero)
        penalty = in_period(details, p.number, true, zero)

        %{
          p
          | fees: fee,
            penalties: penalty,
            total: p.total |> ECBMoney.plus(fee) |> ECBMoney.plus(penalty)
        }
      end)

    total_charged = ECBMoney.plus(fees, penalties)

    schedule
    |> Map.put(:periods, periods)
    |> Map.put(:total_fees, fees)
    |> Map.put(:total_penalties, penalties)
    |> Map.put(
      :total_repayment_expected,
      ECBMoney.plus(schedule.total_repayment_expected, total_charged)
    )
    |> Map.put(:disbursement_fees, Enum.reduce(at_disbursement, zero, &ECBMoney.plus(&2, &1)))
    |> Map.put(:disbursement_fees_shown, shown_at_disbursement(details))
  end

  # a flat charge at disbursement shows as it was given, a percentage as the currency rounds it
  defp shown_at_disbursement(details) do
    case for(%{shown: shown} <- details, do: shown) do
      [] -> nil
      shown -> Enum.reduce(shown, &Decimal.add/2)
    end
  end

  defp sum_for(details, penalty?, zero) do
    details
    |> Enum.filter(&(&1.charge.penalty == penalty?))
    |> Enum.reduce(zero, &ECBMoney.plus(&2, &1.total))
  end

  defp in_period(details, number, penalty?, zero) do
    for d <- details,
        d.charge.penalty == penalty?,
        {^number, money} <- d.installments,
        reduce: zero,
        do: (sum -> ECBMoney.plus(sum, money))
  end

  defp zero(schedule),
    do: ECBMoney.zero(ECBMoney.currency(schedule.principal), schedule.principal.context)
end
