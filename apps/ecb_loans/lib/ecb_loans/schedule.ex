defmodule ECBLoans.Schedule do
  @moduledoc """
  Works out a loan's repayment schedule: when each installment falls due and how much principal and interest it
  carries. A port of Fineract's cumulative schedule generators
  (`AbstractCumulativeLoanScheduleGenerator`, `CumulativeDecliningBalanceInterestLoanScheduleGenerator`,
  `CumulativeFlatInterestLoanScheduleGenerator`) and of the parts of `LoanApplicationTerms` they use, for the core
  term loan: one disbursement, no interest recalculation, no down payment.

  Amounts are `ECBMoney`, rounded to the currency's decimals after every step as Fineract rounds them, and the
  rate arithmetic carries 19 significant digits. `generate/1` takes the loan's terms (see
  `ECBLoans.Schedule.Terms`) and returns the periods and totals.

  The EMI of an equal-installment loan comes from the spreadsheet `PMT` formula worked in floating point, as in
  Fineract; everything else is decimal.

  A schedule can also be worked out again in the middle (`generate/2` with `:variations` and `:resume`), as a
  loan reschedule does: the installments before the date are kept as they are, and the rest is made again with
  the *term variations* an approved reschedule request gives (a moved due date, a new rate from an installment,
  grace on principal or interest, extra installments). The variations are maps
  `%{id:, type:, from:, decimal:, date:, specific?:}` with Fineract's type numbers (see `@types`).
  """
  alias ECBLoans.Schedule.{Charges, Dates, Rates}
  alias ECBMoney.Precision

  @max_periods 10_000

  # Fineract's `LoanTermVariationType`
  @due_date 4
  @grace_on_interest 7
  @grace_on_principal 8
  @extend_repayment_period 9
  @interest_rate_from_installment 10

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

  Options: `:variations` (the term variations to apply) and `:resume`, `%{periods: [period],
  total_interest_due: ECBMoney.t()}`: the installments that stay, which the schedule carries on from.
  """
  @spec generate(map, keyword) :: map
  def generate(terms, opts \\ []) do
    zero = ECBMoney.zero(terms.currency, terms.context)
    terms = terms |> Map.put(:loan_end_date, Dates.last_repayment_date(terms)) |> with_graces()
    variations = opts |> Keyword.get(:variations, []) |> sort_variations()
    terms = end_date_from_variation(terms, variations)

    first_date = Dates.next_repayment_date(terms.repayment_start, terms, true)
    ideal = Dates.minus(first_date, terms.repayment_frequency, terms.repayment_every)

    state = %{
      terms: terms,
      zero: zero,
      total_interest_due: zero,
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
      periods: [],
      # what the variations changed on the way
      exclude_periods: 0,
      periods_completed: 0,
      principal_accounted: zero,
      interest_accounted: zero,
      principal_accounted_for_interest: zero,
      exceptions:
        Enum.filter(
          variations,
          &(&1.type in [@grace_on_interest, @grace_on_principal, @extend_repayment_period])
        ),
      due_dates: Enum.filter(variations, &(&1.type == @due_date)),
      rates_from_installment:
        Enum.filter(variations, &(&1.type == @interest_rate_from_installment)),
      processed: MapSet.new()
    }

    state = %{state | total_interest_due: initial_interest_due(state)}

    state
    |> start_amortization()
    |> resume(Keyword.get(opts, :resume))
    |> loop()
    |> finish()
    |> with_charges(terms)
  end

  defp with_charges(schedule, terms) do
    {schedule, details} = Charges.apply_to(schedule, terms)
    Map.put(schedule, :charge_details, details)
  end

  # the period numbers the grace on principal and on interest apply to (Fineract keeps them as sets, as
  # variations can add more)
  defp with_graces(terms) do
    terms
    |> Map.put(:principal_set, MapSet.new(1..terms.grace_principal//1))
    |> Map.put(:interest_set, MapSet.new(1..terms.grace_interest//1))
  end

  defp sort_variations(variations) do
    Enum.sort_by(variations, fn v -> {Date.to_gregorian_days(v.from), same_date_order(v.type)} end)
  end

  # `LoanTermVariationsData.sameDateOrder`: a due date first, then the graces, the extension, the rest
  defp same_date_order(@due_date), do: -1
  defp same_date_order(@grace_on_interest), do: 0
  defp same_date_order(@grace_on_principal), do: 0
  defp same_date_order(@extend_repayment_period), do: 1
  defp same_date_order(_), do: 2

  # a due date variation on the loan's last date moves the end of the loan
  defp end_date_from_variation(terms, variations) do
    case Enum.find(variations, &(&1.type == @due_date and &1.from == terms.loan_end_date)) do
      nil -> terms
      variation -> %{terms | loan_end_date: variation.date}
    end
  end

  defp initial_interest_due(%{terms: terms, zero: zero} = state),
    do: if(flat?(terms), do: total_interest_charged(state), else: zero)

  # --- carrying on from the installments that stay ------------------------------------------------

  defp resume(state, nil), do: state

  defp resume(state, %{periods: kept, total_interest_due: total}) do
    principal = sum(kept, :principal, state.zero)
    interest = sum(kept, :interest, state.zero)
    last = List.last(kept)

    %{
      state
      | periods: kept,
        period_number: length(kept) + 1,
        period_start: last.due,
        actual_date: last.due,
        first?: false,
        balance: ECBMoney.minus(state.terms.principal, principal),
        balance_per_rest: ECBMoney.minus(state.terms.principal, principal),
        cumulative_principal: principal,
        cumulative_interest: interest,
        total_repayment: sum(kept, :total, state.zero),
        total_fees: sum(kept, :fees, state.zero),
        total_penalties: sum(kept, :penalties, state.zero),
        total_interest_due: total,
        term_days: Dates.days_between(last.from, last.due)
    }
  end

  defp sum(periods, key, zero),
    do: Enum.reduce(periods, zero, &ECBMoney.plus(&2, Map.fetch!(&1, key)))

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
    state = %{state | first?: false}
    {state, due} = apply_variations(state, due)
    start = state.period_start

    if Date.compare(start, due) == :gt,
      do: raise(ArgumentError, "Due date can't be before period start date")

    state = ensure_emi(state)
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

  # An EMI that a variation took away is worked out again from what is left when it is next needed
  # (`LoanApplicationTerms.paymentPerPeriod`).
  defp ensure_emi(%{fixed_emi: nil, terms: %{amortization: 1, interest_method: 0}} = state),
    do: %{state | fixed_emi: emi(state, state.balance_per_rest, state.period_number)}

  defp ensure_emi(state), do: state

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

  # --- the term variations ------------------------------------------------------------------------

  # `applyLoanTermVariations`: what a reschedule changes, applied as the schedule reaches it. Returns the state
  # and the due date of the period (a moved due date changes it).
  defp apply_variations(state, due) do
    {state, due} = due_date_variation(state, due)
    state = rates_from_installment(state, due)
    {exceptions(state, due), due}
  end

  # a due date that moves applies to the one date it was asked for
  defp due_date_variation(%{due_dates: [variation | rest]} = state, due) do
    cond do
      Date.compare(variation.from, due) == :gt -> {state, due}
      variation.from == due -> {moved(%{state | due_dates: rest}, variation), variation.date}
      true -> {%{state | due_dates: rest}, due}
    end
  end

  defp due_date_variation(state, due), do: {state, due}

  # the next due dates follow the new one, unless the move is for that installment alone
  defp moved(state, %{specific?: true}), do: state
  defp moved(state, variation), do: %{state | actual_date: variation.date}

  defp rates_from_installment(state, due) do
    Enum.reduce(state.rates_from_installment, state, fn variation, state ->
      if Date.compare(variation.from, due) != :gt and variation.decimal != nil and
           not MapSet.member?(state.processed, variation.id) do
        state |> new_rate(variation.decimal) |> mark(variation)
      else
        state
      end
    end)
  end

  defp new_rate(%{terms: terms} = state, rate) do
    state = %{state | terms: %{terms | annual_rate: rate}, fixed_emi: nil}

    if flat?(terms) do
      state = %{state | principal_accounted_for_interest: state.cumulative_principal}
      total = ECBMoney.plus(total_interest_charged(state), state.cumulative_interest)
      %{state | total_interest_due: total, exclude_periods: state.period_number - 1}
    else
      state
    end
  end

  defp mark(state, variation), do: %{state | processed: MapSet.put(state.processed, variation.id)}

  # the extension and the graces, in order, up to the date
  defp exceptions(%{exceptions: [variation | rest]} = state, due) do
    if Date.compare(variation.from, due) == :gt do
      state
    else
      state |> Map.put(:exceptions, rest) |> exception(variation) |> exceptions(due)
    end
  end

  defp exceptions(state, _due), do: state

  defp exception(%{terms: terms} = state, %{type: @extend_repayment_period} = variation) do
    count = terms.number_of_repayments + Decimal.to_integer(variation.decimal)
    terms = %{terms | number_of_repayments: count}
    terms = %{terms | loan_end_date: Dates.last_repayment_date(terms)}

    state = %{
      state
      | terms: terms,
        periods_completed: state.period_number - 1,
        principal_accounted: state.cumulative_principal,
        interest_accounted: state.cumulative_interest
    }

    state |> adjust_installment_or_principal() |> mark(variation)
  end

  defp exception(%{terms: terms} = state, %{type: @grace_on_principal} = variation) do
    count = Decimal.to_integer(variation.decimal)
    terms = %{terms | grace_principal: count, grace_interest: 0}
    state |> Map.put(:terms, terms) |> add_grace_periods() |> mark(variation)
  end

  defp exception(%{terms: terms} = state, %{type: @grace_on_interest} = variation) do
    count = Decimal.to_integer(variation.decimal)
    terms = %{terms | grace_interest: count, grace_principal: 0}

    state
    |> Map.put(:terms, terms)
    |> add_grace_periods()
    |> Map.put(:interest_accounted, state.cumulative_interest)
    |> mark(variation)
  end

  # `updatePeriodNumberApplicableForPrincipalOrInterestGrace`: the next periods are grace periods
  defp add_grace_periods(%{terms: terms} = state) do
    first = state.period_number

    principal =
      if terms.grace_principal > 0,
        do: Enum.to_list(first..(first + terms.grace_principal - 1)),
        else: []

    interest =
      if terms.grace_interest > 0,
        do: Enum.to_list(first..(first + terms.grace_interest - 1)),
        else: []

    terms = %{
      terms
      | principal_set: MapSet.union(terms.principal_set, MapSet.new(principal)),
        interest_set: MapSet.union(terms.interest_set, MapSet.new(interest))
    }

    %{state | terms: terms}
  end

  # `adjustInstallmentOrPrincipalAmount`: what is left to pay is spread over the periods that are left
  defp adjust_installment_or_principal(%{terms: terms} = state) do
    left = ECBMoney.minus(terms.principal, state.cumulative_principal)

    cond do
      not ECBMoney.positive?(left) ->
        state

      terms.amortization == 0 ->
        count = remaining_principal_periods(terms, state.period_number - 1)
        %{state | fixed_principal: ECBMoney.divide(left, count)}

      terms.interest_method == 0 ->
        period = max(state.period_number, terms.grace_principal + 1)
        %{state | fixed_emi: emi(state, left, period)}

      true ->
        state
    end
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
    per = flat_per_installment(state)

    cond do
      interest_payment_grace?(terms, number) ->
        {zero, ECBMoney.plus(carried, per)}

      free_period?(terms, number) ->
        {zero, carried}

      number > 0 and number == terms.grace_interest + 1 ->
        {ECBMoney.plus(carried, per), zero}

      true ->
        {per, carried}
    end
  end

  # equal installments: what is left of the interest, spread over the periods that carry it
  defp flat_averaged_interest(%{terms: terms} = state, number) do
    total = flat_total(state)
    per = flat_per_installment(state)
    free = ECBMoney.times(per, terms.grace_interest_charged)
    real = ECBMoney.minus(total, free)

    interest = ECBMoney.divide(real, remaining_interest_periods(terms, state.exclude_periods))

    interest =
      if state.exclude_periods < state.periods_completed do
        left = ECBMoney.minus(state.total_interest_due, state.interest_accounted)
        ECBMoney.divide(left, remaining_interest_periods(terms, state.periods_completed))
      else
        interest
      end

    if MapSet.size(terms.interest_set) > 0 do
      elapsed = last_interest_grace_period(terms, number)

      if elapsed > state.exclude_periods and elapsed > state.periods_completed do
        left = ECBMoney.minus(state.total_interest_due, state.interest_accounted)
        ECBMoney.divide(left, remaining_interest_periods(terms, elapsed))
      else
        interest
      end
    else
      interest
    end
  end

  defp last_interest_grace_period(terms, number) do
    terms.interest_set |> Enum.filter(&(&1 < number)) |> Enum.max(fn -> 0 end)
  end

  defp flat_principal(%{terms: terms} = state, number, interest) do
    zero = state.zero
    count = remaining_principal_periods(terms, state.periods_completed)

    per =
      terms.principal
      |> ECBMoney.minus(state.principal_accounted)
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

  defp total_interest_charged(%{terms: terms} = state) do
    total = flat_total(state)
    per = flat_per_installment(state)
    grace = ECBMoney.multiply_retain_scale(per, terms.grace_interest_charged)
    ECBMoney.minus(total, grace)
  end

  # all the term's interest, as if there were no grace
  defp flat_total(%{terms: terms} = state) do
    rate = Rates.flat_for_term(terms)

    terms.principal
    |> ECBMoney.minus(state.principal_accounted_for_interest)
    |> ECBMoney.multiply_retain_scale(rate)
  end

  # `flatInterestPerInstallment`
  defp flat_per_installment(%{terms: terms} = state) do
    per = ECBMoney.divide(flat_total(state), terms.number_of_repayments - state.exclude_periods)

    if state.exclude_periods < state.periods_completed do
      left = ECBMoney.minus(state.total_interest_due, state.interest_accounted)
      ECBMoney.divide(left, terms.number_of_repayments - state.periods_completed)
    else
      per
    end
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

  defp principal_grace?(terms, number), do: MapSet.member?(terms.principal_set, number)
  defp interest_payment_grace?(terms, number), do: MapSet.member?(terms.interest_set, number)
  defp free_period?(terms, number), do: number > 0 and number <= terms.grace_interest_charged

  defp remaining_principal_periods(terms, elapsed) do
    graces = Enum.count(terms.principal_set, &(&1 > elapsed))
    terms.number_of_repayments - elapsed - graces
  end

  defp remaining_interest_periods(terms, elapsed) do
    graces = Enum.count(terms.interest_set, &(&1 > elapsed))
    terms.number_of_repayments - elapsed - graces - terms.grace_interest_charged
  end

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
