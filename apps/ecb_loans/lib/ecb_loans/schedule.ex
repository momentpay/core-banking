defmodule ECBLoans.Schedule do
  @moduledoc """
  Works out a loan's repayment schedule: when each installment falls due and how much principal and interest it
  carries. A port of Fineract's cumulative schedule generators
  (`AbstractCumulativeLoanScheduleGenerator`, `CumulativeDecliningBalanceInterestLoanScheduleGenerator`,
  `CumulativeFlatInterestLoanScheduleGenerator`) and of the parts of `LoanApplicationTerms` they use, for the core
  term loan: one disbursement, no interest recalculation, no variations of the terms, no down payment.

  Amounts are `ECBMoney`, rounded to the currency's decimals after every step as Fineract rounds them, and the
  rate arithmetic carries 19 significant digits. `generate/1` takes the loan's terms (see
  `ECBLoans.Schedule.Terms`) and returns the periods and totals.

  The EMI of an equal-installment loan comes from the spreadsheet `PMT` formula worked in floating point, as in
  Fineract; everything else is decimal.
  """
  alias ECBLoans.Schedule.{Dates, Rates}
  alias ECBMoney.Precision

  @max_periods 10_000

  @type period :: %{
          number: pos_integer,
          from: Date.t(),
          due: Date.t(),
          principal: ECBMoney.t(),
          balance: ECBMoney.t(),
          interest: ECBMoney.t(),
          fees: ECBMoney.t(),
          penalties: ECBMoney.t(),
          total: ECBMoney.t()
        }

  @doc """
  The schedule for `terms`: `%{periods: [period], disbursement_date:, total_principal_expected:,
  total_interest:, total_fees:, total_penalties:, total_repayment_expected:, loan_term_in_days:}`.
  """
  @spec generate(map) :: map
  def generate(terms) do
    zero = ECBMoney.zero(terms.currency, terms.context)
    terms = Map.put(terms, :loan_end_date, Dates.last_repayment_date(terms))

    total_interest_due = if flat?(terms), do: total_interest_charged(terms, zero), else: zero
    first_date = Dates.next_repayment_date(terms.repayment_start, terms, true)
    ideal = Dates.minus(first_date, terms.repayment_frequency, terms.repayment_every)

    state = %{
      terms: terms,
      zero: zero,
      total_interest_due: total_interest_due,
      first_repayment_date: first_date,
      ideal_disbursement_date: ideal,
      fixed_emi: nil,
      fixed_principal: nil,
      period_number: 1,
      period_start: terms.repayment_start,
      actual_date: terms.repayment_start,
      first?: true,
      balance: terms.principal,
      balance_per_rest: terms.principal,
      cumulative_principal: zero,
      cumulative_interest: zero,
      total_fees: zero,
      total_penalties: zero,
      total_repayment: zero,
      interest_due_to_grace: zero,
      term_days: 0,
      periods: []
    }

    state |> start_amortization() |> loop() |> finish()
  end

  # --- amortization set-up ------------------------------------------------------------------

  defp start_amortization(%{terms: %{amortization: 1, interest_method: 0}} = state) do
    period = max(1, state.terms.grace_principal + 1)
    %{state | fixed_emi: emi(state, state.terms.principal, period)}
  end

  defp start_amortization(%{terms: terms} = state) do
    count = remaining_principal_periods(terms, 0)
    %{state | fixed_principal: ECBMoney.divide(terms.principal, count)}
  end

  # --- one period after another -----------------------------------------------------------------

  defp loop(%{periods: periods}) when length(periods) > @max_periods,
    do: raise(ArgumentError, "the schedule does not end")

  defp loop(state) do
    if ECBMoney.zero?(state.balance) do
      state
    else
      state |> next_period() |> loop()
    end
  end

  defp next_period(%{terms: terms} = state) do
    due = Dates.next_repayment_date(state.actual_date, terms, state.first?)
    start = state.period_start

    if Date.compare(start, due) == :gt,
      do: raise(ArgumentError, "Due date can't be before period start date")

    interest_from = interest_start_date(state, start)
    {principal, interest, grace_interest} = principal_and_interest(state, interest_from, due)

    balance = ECBMoney.minus(state.balance, principal)

    {principal, balance} =
      if ECBMoney.negative?(balance),
        do: {ECBMoney.plus(principal, balance), state.zero},
        else: {principal, balance}

    total = principal |> ECBMoney.plus(interest) |> ECBMoney.plus(state.zero)

    period = %{
      number: state.period_number,
      from: start,
      due: due,
      principal: principal,
      balance: balance,
      interest: interest,
      fees: state.zero,
      penalties: state.zero,
      total: total
    }

    %{
      state
      | periods: state.periods ++ [period],
        actual_date: due,
        first?: false,
        period_start: due,
        period_number: state.period_number + 1,
        balance: balance,
        balance_per_rest: ECBMoney.minus(state.balance_per_rest, principal),
        cumulative_principal: ECBMoney.plus(state.cumulative_principal, principal),
        cumulative_interest: ECBMoney.plus(state.cumulative_interest, interest),
        total_repayment: ECBMoney.plus(state.total_repayment, total),
        interest_due_to_grace: grace_interest,
        term_days: state.term_days + Dates.days_between(start, due)
    }
  end

  defp interest_start_date(state, start) do
    terms = state.terms

    if (Date.compare(start, state.ideal_disbursement_date) == :lt or
          Date.compare(start, state.first_repayment_date) == :lt) and
         Date.compare(start, terms.disbursement_date) == :eq,
       do: state.ideal_disbursement_date,
       else: start
  end

  defp finish(state) do
    state =
      if ECBMoney.positive?(state.interest_due_to_grace) do
        {last, rest} = List.pop_at(state.periods, -1)

        last = %{
          last
          | interest: ECBMoney.plus(last.interest, state.interest_due_to_grace),
            total: ECBMoney.plus(last.total, state.interest_due_to_grace)
        }

        %{
          state
          | periods: rest ++ [last],
            total_repayment: ECBMoney.plus(state.total_repayment, state.interest_due_to_grace),
            cumulative_interest:
              ECBMoney.plus(state.cumulative_interest, state.interest_due_to_grace)
        }
      else
        state
      end

    %{
      periods: state.periods,
      disbursement_date: state.terms.disbursement_date,
      principal: state.terms.principal,
      total_principal_expected: state.cumulative_principal,
      total_interest: state.cumulative_interest,
      total_fees: state.total_fees,
      total_penalties: state.total_penalties,
      total_repayment_expected: state.total_repayment,
      loan_term_in_days: state.term_days
    }
  end

  # --- principal and interest of one period ------------------------------------------------------

  defp principal_and_interest(%{terms: %{interest_method: 0}} = state, from, to),
    do: declining(state, from, to)

  defp principal_and_interest(state, from, to), do: flat(state, from, to)

  # Declining balance: interest on what is still owed, principal from the EMI or an equal share.
  defp declining(%{terms: terms} = state, from, to) do
    number = state.period_number
    carried = state.interest_due_to_grace
    before_grace = declining_interest(terms, state.balance_per_rest, from, to)

    after_grace =
      if interest_payment_grace?(terms, number) or free_period?(terms, number),
        do: ECBMoney.zero(terms.currency, terms.context),
        else: before_grace

    {interest, carried_after} =
      cond do
        ECBMoney.positive?(after_grace) ->
          {ECBMoney.plus(carried, after_grace), ECBMoney.zero(terms.currency, terms.context)}

        free_period?(terms, number) ->
          {ECBMoney.zero(terms.currency, terms.context), carried}

        true ->
          {after_grace, ECBMoney.plus(carried, before_grace)}
      end

    interest_for_period =
      if ECBMoney.positive?(interest),
        do: ECBMoney.minus(interest, carried),
        else: ECBMoney.minus(carried_after, carried)

    principal = declining_principal(state, interest_for_period)

    principal =
      adjust_principal(
        terms,
        principal,
        ECBMoney.plus(state.cumulative_principal, principal),
        number
      )

    {principal, interest, carried_after}
  end

  defp declining_interest(terms, balance, from, to) do
    rate = Rates.periodic(terms, terms.days_in_month, terms.days_in_year, from, to, false)
    ECBMoney.multiply_retain_scale(balance, rate)
  end

  defp declining_principal(%{terms: %{amortization: 1}} = state, interest_for_period) do
    emi = state.fixed_emi
    number = state.period_number
    principal = ECBMoney.minus(emi, interest_for_period)

    if principal_grace?(state.terms, number),
      do: ECBMoney.zero(state.terms.currency, state.terms.context),
      else: principal
  end

  defp declining_principal(%{terms: terms} = state, _interest) do
    if principal_grace?(terms, state.period_number),
      do: ECBMoney.zero(terms.currency, terms.context),
      else: ECBMoney.new(terms.currency, state.fixed_principal.amount, terms.context)
  end

  # Flat interest: the whole term's interest is fixed up front and shared out over the installments.
  defp flat(%{terms: terms} = state, _from, _to) do
    number = state.period_number
    carried = state.interest_due_to_grace
    {interest, carried_after} = flat_interest(state, number, carried)

    principal = flat_principal(state, number, interest)

    cumulative_interest = ECBMoney.plus(state.cumulative_interest, interest)

    principal =
      adjust_principal(
        terms,
        principal,
        ECBMoney.plus(state.cumulative_principal, principal),
        number
      )

    interest =
      adjust_interest(terms, interest, cumulative_interest, state.total_interest_due, number)

    {principal, interest, carried_after}
  end

  defp flat_interest(%{terms: %{amortization: 1} = terms} = state, number, carried) do
    zero = ECBMoney.zero(terms.currency, terms.context)

    interest =
      cond do
        interest_payment_grace?(terms, number) -> zero
        free_period?(terms, number) -> zero
        true -> flat_averaged_interest(state, number)
      end

    {interest, carried}
  end

  defp flat_interest(%{terms: terms} = state, number, carried) do
    zero = ECBMoney.zero(terms.currency, terms.context)
    per = flat_per_installment(terms, zero)

    cond do
      interest_payment_grace?(terms, number) ->
        {zero, ECBMoney.plus(carried, per)}

      free_period?(terms, number) ->
        {zero, carried}

      number > 0 and number == terms.grace_interest + 1 ->
        _ = state
        {ECBMoney.plus(carried, per), zero}

      true ->
        {per, carried}
    end
  end

  # equal installments: what is left of the interest, spread over the periods that carry it
  defp flat_averaged_interest(%{terms: terms} = state, number) do
    zero = state.zero
    total = flat_total(terms, zero)
    per = flat_per_installment(terms, zero)
    free = ECBMoney.times(per, terms.grace_interest_charged)
    real = ECBMoney.minus(total, free)
    periods = remaining_interest_periods(terms, 0)
    interest = ECBMoney.divide(real, periods)

    grace_periods = interest_grace_periods(terms)

    if grace_periods != [] do
      elapsed = grace_periods |> Enum.filter(&(&1 < number)) |> Enum.max(fn -> 0 end)

      if elapsed > 0 do
        left = ECBMoney.minus(state.total_interest_due, zero)
        ECBMoney.divide(left, remaining_interest_periods(terms, elapsed))
      else
        interest
      end
    else
      interest
    end
  end

  defp flat_principal(%{terms: terms} = state, number, interest) do
    zero = state.zero
    count = remaining_principal_periods(terms, 0)

    per =
      terms.principal
      |> ECBMoney.divide(count)

    per = if principal_grace?(terms, number), do: zero, else: per

    if terms.installment_multiples_of do
      rounded = ECBMoney.round_to_multiples_of(per, terms.installment_multiples_of)
      rounded_interest = ECBMoney.round_to_multiples_of(interest, terms.installment_multiples_of)

      rounded
      |> ECBMoney.plus(rounded_interest)
      |> ECBMoney.minus(interest)
    else
      per
    end
  end

  # --- flat interest totals ---------------------------------------------------------------------

  defp flat?(terms), do: terms.interest_method == 1

  defp total_interest_charged(terms, zero) do
    total = flat_total(terms, zero)
    per = flat_per_installment(terms, zero)
    grace = ECBMoney.multiply_retain_scale(per, terms.grace_interest_charged)
    ECBMoney.minus(total, grace)
  end

  # all the term's interest, as if there were no grace
  defp flat_total(terms, _zero) do
    rate = Rates.flat_for_term(terms)
    ECBMoney.multiply_retain_scale(terms.principal, rate)
  end

  defp flat_per_installment(terms, zero) do
    ECBMoney.divide(flat_total(terms, zero), terms.number_of_repayments)
  end

  # --- the EMI -------------------------------------------------------------------------------

  defp emi(%{terms: terms}, balance, period_number) do
    start = %{terms.disbursement_date | day: 1}
    finish = Dates.plus(start, terms.repayment_frequency, terms.repayment_every)
    rate = Rates.periodic(terms, 30, 365, start, finish, true)

    remaining = remaining_principal_periods(terms, period_number - 1)

    payment =
      pmt(
        Decimal.to_float(rate),
        remaining * 1.0,
        -Decimal.to_float(ECBMoney.amount(balance)),
        0.0
      )

    amount = Decimal.from_float(payment)

    amount =
      if terms.installment_multiples_of,
        do: round_multiples(amount, terms.installment_multiples_of, terms.context.rounding),
        else: amount

    ECBMoney.new(terms.currency, amount, terms.context)
  end

  # amount / multiple rounded to a whole number, times multiple (`BigDecimal.divide(m, 0, mode) * m`)
  defp round_multiples(amount, multiple, rounding) do
    quotient =
      Decimal.Context.with(%Decimal.Context{precision: 60, rounding: rounding}, fn ->
        amount |> Decimal.div(Decimal.new(multiple)) |> Decimal.round(0, rounding)
      end)

    Precision.exact(fn -> Decimal.mult(quotient, Decimal.new(multiple)) end)
  end

  @doc false
  # The spreadsheet PMT function, in floating point as Fineract works it.
  def pmt(rate, periods, principal, future_value) do
    if rate == 0 do
      -1 * (future_value + principal) / periods
    else
      growth = rate + 1
      power = :math.pow(growth, periods)
      (future_value + principal * power) * rate / (1 * (1 - power))
    end
  end

  # --- grace and counting periods ----------------------------------------------------------

  defp principal_grace?(terms, number), do: number >= 1 and number <= terms.grace_principal
  defp interest_payment_grace?(terms, number), do: number >= 1 and number <= terms.grace_interest
  defp free_period?(terms, number), do: number > 0 and number <= terms.grace_interest_charged

  defp interest_grace_periods(%{grace_interest: 0}), do: []
  defp interest_grace_periods(%{grace_interest: count}), do: Enum.to_list(1..count)

  defp remaining_principal_periods(terms, elapsed) do
    graces = Enum.count(principal_grace_list(terms), &(&1 > elapsed))
    terms.number_of_repayments - elapsed - graces
  end

  defp remaining_interest_periods(terms, elapsed) do
    graces = Enum.count(interest_grace_periods(terms), &(&1 > elapsed))
    terms.number_of_repayments - elapsed - graces - terms.grace_interest_charged
  end

  defp principal_grace_list(%{grace_principal: 0}), do: []
  defp principal_grace_list(%{grace_principal: count}), do: Enum.to_list(1..count)

  # --- the last installment takes up what is left --------------------------------------------

  defp adjust_principal(terms, principal, cumulative, number) do
    remaining = ECBMoney.minus(terms.principal, cumulative)

    cond do
      ECBMoney.negative?(remaining) ->
        ECBMoney.minus(principal, ECBMoney.abs(remaining))

      number == terms.number_of_repayments ->
        difference = ECBMoney.minus(cumulative, terms.principal)

        cond do
          ECBMoney.negative?(difference) -> ECBMoney.plus(principal, ECBMoney.abs(difference))
          ECBMoney.positive?(difference) -> ECBMoney.minus(principal, ECBMoney.abs(difference))
          true -> principal
        end

      true ->
        principal
    end
  end

  defp adjust_interest(terms, interest, cumulative, total_due, number) do
    remaining = ECBMoney.minus(total_due, cumulative)

    adjusted =
      cond do
        ECBMoney.negative?(remaining) ->
          ECBMoney.minus(interest, ECBMoney.abs(remaining))

        number == terms.number_of_repayments ->
          difference = ECBMoney.minus(cumulative, total_due)

          cond do
            ECBMoney.negative?(difference) -> ECBMoney.plus(interest, ECBMoney.abs(difference))
            ECBMoney.positive?(difference) -> ECBMoney.minus(interest, ECBMoney.abs(difference))
            true -> interest
          end

        true ->
          interest
      end

    # Fineract doubles a negative amount here instead of making it zero
    if ECBMoney.negative?(adjusted), do: ECBMoney.plus(adjusted, adjusted), else: adjusted
  end
end
