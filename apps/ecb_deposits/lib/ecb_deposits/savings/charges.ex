defmodule ECBDeposits.Savings.Charges do
  @moduledoc """
  The charges of a savings account (`m_savings_account_charge`), after Fineract's `SavingsAccountCharge`,
  `SavingsAccountChargeReadPlatformServiceImpl` and `SavingsAccountChargeAssembler`: reading them, and the
  rules of a charge (when it next falls due, how much it is, how it is paid or waived). The commands that change them
  are in `ECBDeposits.Savings.ChargeCommands`. Must run inside a tenant scope.

  Times a charge falls due (`:time`): 2 specified due date, 3 savings activation, 4 closure, 5 withdrawal fee, 6 annual
  fee, 7 monthly fee, 10 overdraft fee, 11 weekly fee, 16 no activity fee. Calculations: 1 flat, 2 percentage of
  the amount.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @specified 2
  @activation 3
  @withdrawal_fee 5
  @annual 6
  @monthly 7
  @weekly 11
  @no_activity 16

  @select """
  SELECT sc.id, sc.savings_account_id AS account_id, sc.charge_id, c.name, sc.charge_time_enum AS time,
         sc.charge_due_date AS due_date, sc.fee_on_month, sc.fee_on_day, sc.fee_interval,
         sc.charge_calculation_enum AS calculation, sc.calculation_percentage AS percentage,
         sc.calculation_on_amount AS applied_to, sc.amount, sc.amount_paid_derived AS paid,
         sc.amount_waived_derived AS waived_amount, sc.amount_writtenoff_derived AS written_off,
         sc.amount_outstanding_derived AS outstanding, sc.is_penalty AS penalty, sc.is_paid_derived AS is_paid,
         sc.waived, sc.is_active, sc.inactivated_on_date, sc.free_withdrawal_count, sc.charge_reset_date,
         c.is_free_withdrawal, c.free_withdrawal_charge_frequency AS free_frequency, c.restart_frequency,
         c.restart_frequency_enum, c.is_payment_type, c.payment_type_id, c.income_or_liability_account_id AS gl_account_id
  FROM m_savings_account_charge sc
  JOIN m_charge c ON c.id = sc.charge_id
  """

  # --- reads --------------------------------------------------------------------------------------

  @doc """
  The charges of an account (`status`: all, active or inactive) in the order they were made.
  """
  @spec list(integer, String.t()) :: [map]
  def list(account_id, status \\ "all") do
    filter =
      case String.downcase(status) do
        "active" -> " AND sc.is_active"
        "inactive" -> " AND NOT sc.is_active"
        _ -> ""
      end

    query("WHERE sc.savings_account_id = $1" <> filter <> " ORDER BY sc.id", [account_id])
  end

  @doc "One charge of the account, or `nil`."
  @spec get(integer, integer) :: map | nil
  def get(account_id, id),
    do:
      "WHERE sc.savings_account_id = $1 AND sc.id = $2" |> query([account_id, id]) |> List.first()

  @doc "A charge of any account, or `nil`."
  @spec get(integer) :: map | nil
  def get(id), do: "WHERE sc.id = $1" |> query([id]) |> List.first()

  defp query(where, params) do
    %{columns: columns, rows: rows} = TenantRepo.query!(@select <> where, params)
    atoms = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> atoms |> Enum.zip(row) |> Map.new() end)
  end

  @doc "The error for a charge that is not there, as the commands name it (by the charge)."
  @spec not_found(term) :: Exception.t()
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.savings.account.charge.id.invalid",
        "Savings Account charge with identifier #{id} does not exist",
        [id]
      )

  @doc "The error for a charge that is not there, as reading it names it (by the account)."
  @spec not_found_on_read(term) :: Exception.t()
  def not_found_on_read(account_id), do: not_found(account_id)

  # --- what a charge is ---------------------------------------------------------------------------

  def specified_due_date?(c), do: c.time == @specified
  def activation?(c), do: c.time == @activation
  def withdrawal_fee?(c), do: c.time == @withdrawal_fee
  def annual?(c), do: c.time == @annual
  def monthly?(c), do: c.time == @monthly
  def weekly?(c), do: c.time == @weekly
  def no_activity?(c), do: c.time == @no_activity
  def recurring?(c), do: c.time in [@annual, @monthly, @weekly]
  def flat?(c), do: c.calculation == 1

  @doc "Charges that, when paid, may take an account below its minimum balance (all but activation and withdrawal fees)."
  def overrides_balance_rules?(c), do: not activation?(c) and not withdrawal_fee?(c)

  @doc "What the charge asks for: its amount when flat, its percentage otherwise."
  def amount_or_percentage(%{calculation: 1, amount: amount}), do: amount
  def amount_or_percentage(%{percentage: percentage}), do: percentage || Decimal.new(0)

  # --- when a recurring charge falls due ------------------------------------------------------------

  @doc """
  The next day the charge falls due from `start`, after `SavingsAccountCharge.getNextDueDateFrom`: for annual and
  monthly fees the first day on the day of the month they fall on that is not before `start`; for a weekly fee the
  first one of its cycle; for the rest a cycle after.
  """
  @spec next_due_from(map, Date.t()) :: Date.t() | nil
  def next_due_from(%{time: time} = c, start) when time in [@annual, @monthly] do
    start |> with_month(c.fee_on_month) |> set_day(c) |> roll(c, start)
  end

  def next_due_from(%{time: @weekly} = c, start), do: roll(c.due_date, c, start)
  def next_due_from(c, start), do: next(c, start)

  defp roll(date, c, start) do
    if Date.compare(date, start) == :lt,
      do: date |> then(&next(c, &1)) |> roll(c, start),
      else: date
  end

  @doc "The day after `date` the charge falls due on, after `calculateNextDueDate`."
  @spec next(map, Date.t()) :: Date.t() | nil
  def next(%{time: @annual} = c, date),
    do: date |> with_month(c.fee_on_month) |> Date.shift(year: 1) |> set_day(c)

  def next(%{time: @monthly} = c, date),
    do: date |> Date.shift(month: c.fee_interval) |> set_day(c)

  def next(%{time: @weekly} = c, date),
    do: date |> Date.shift(week: c.fee_interval) |> set_day_of_week(c)

  def next(_c, _date), do: nil

  @doc "The previous day, as `updateToPreviousDueDate` takes an undone payment back."
  @spec previous(map, Date.t()) :: Date.t()
  def previous(%{time: @annual} = c, date),
    do: date |> with_month(c.fee_on_month) |> Date.shift(year: -1) |> set_day(c)

  def previous(%{time: @monthly} = c, date),
    do: date |> Date.shift(month: -c.fee_interval) |> set_day(c)

  def previous(%{time: @weekly} = c, date),
    do: date |> Date.add(-7 * c.fee_interval) |> set_day_of_week(c)

  def previous(_c, date), do: date

  defp with_month(date, month) do
    first = Date.new!(date.year, month, 1)
    %{first | day: min(date.day, Date.days_in_month(first))}
  end

  defp set_day(date, %{fee_on_day: day}), do: %{date | day: min(day, Date.days_in_month(date))}

  defp set_day_of_week(date, %{fee_on_day: day}) do
    current = Date.day_of_week(date)
    if current == day, do: date, else: Date.add(date, day - current)
  end

  @doc "What a withdrawal of `withdrawn` costs in this withdrawal fee, to the decimals of the currency."
  @spec withdrawal_fee_amount(map, Decimal.t(), non_neg_integer) :: Decimal.t()
  def withdrawal_fee_amount(%{calculation: 1} = c, _withdrawn, digits),
    do: Decimal.round(c.amount, digits, :half_even)

  def withdrawal_fee_amount(c, withdrawn, digits) do
    withdrawn
    |> Decimal.mult(c.percentage || 0)
    |> Decimal.div(100)
    |> Decimal.round(digits, :half_even)
  end

  # --- paying and waiving -----------------------------------------------------------------------------

  @doc """
  What paying `amount` of the charge leaves: `{paid, outstanding, is_paid, due_date, reset?}` where a charge paid up
  that recurs is made new for its next due date.
  """
  @spec after_payment(map, Decimal.t()) :: map
  def after_payment(c, amount) do
    paid = Decimal.add(c.paid || 0, amount)
    outstanding = Decimal.sub(c.outstanding, amount)
    c = %{c | paid: paid, outstanding: outstanding}
    c = %{c | is_paid: fully_paid?(c)}

    if Decimal.eq?(outstanding, 0) and recurring?(c), do: renew(c), else: c
  end

  @doc false
  # `determineIfFullyPaid`: the amount less what was paid, waived and written off is nothing
  def fully_paid?(c) do
    (c.amount || Decimal.new(0))
    |> Decimal.sub(c.paid || 0)
    |> Decimal.sub(c.waived_amount || 0)
    |> Decimal.sub(c.written_off || 0)
    |> Decimal.eq?(0)
  end

  # a recurring charge paid up falls due again: it is outstanding in full and not paid
  defp renew(c) do
    %{c | due_date: next(c, c.due_date), outstanding: c.amount, is_paid: false, waived: false}
  end

  @doc "What waiving the charge leaves."
  @spec after_waiver(map) :: map
  def after_waiver(c) do
    c = %{
      c
      | waived_amount: Decimal.add(c.waived_amount || 0, c.outstanding),
        outstanding: Decimal.new(0),
        waived: true
    }

    if recurring?(c),
      do: %{
        c
        | outstanding: c.amount,
          is_paid: false,
          waived: false,
          due_date: next(c, c.due_date)
      },
      else: c
  end

  @doc "The charge as it was before a payment of `amount` was undone."
  @spec after_undone_payment(map, Decimal.t()) :: map
  def after_undone_payment(c, amount) do
    paid = Decimal.sub(c.paid || 0, amount)
    outstanding = outstanding_of(%{c | paid: paid})
    outstanding = if withdrawal_fee?(c), do: Decimal.new(0), else: outstanding
    c = %{c | paid: paid, outstanding: outstanding, is_paid: false, is_active: true}

    if recurring?(c),
      do: %{c | outstanding: c.amount, waived: false, due_date: previous(c, c.due_date)},
      else: c
  end

  @doc "The charge as it was before a waiver of `amount` was undone."
  @spec after_undone_waiver(map, Decimal.t()) :: map
  def after_undone_waiver(c, amount) do
    waived = Decimal.sub(c.waived_amount || 0, amount)

    c = %{
      c
      | waived_amount: waived,
        outstanding: outstanding_of(%{c | waived_amount: waived}),
        waived: false,
        is_active: true
    }

    if recurring?(c),
      do: %{c | outstanding: c.amount, due_date: previous(c, c.due_date)},
      else: c
  end

  defp outstanding_of(c) do
    (c.amount || Decimal.new(0))
    |> Decimal.sub(c.waived_amount || 0)
    |> Decimal.sub(c.paid || 0)
  end

  # --- making a charge ---------------------------------------------------------------------------------

  @doc "The definition of a charge (`m_charge`), or `nil`: what a charge of an account is made from."
  @spec definition(integer) :: map | nil
  def definition(id) do
    from(c in "m_charge",
      where: c.id == ^id and c.is_deleted == false,
      select: %{
        id: c.id,
        name: c.name,
        amount: c.amount,
        currency_code: c.currency_code,
        applies_to: c.charge_applies_to_enum,
        time: c.charge_time_enum,
        calculation: c.charge_calculation_enum,
        penalty: c.is_penalty,
        fee_on_month: c.fee_on_month,
        fee_on_day: c.fee_on_day,
        fee_interval: c.fee_interval,
        free_withdrawal: c.is_free_withdrawal,
        payment_type: c.is_payment_type
      }
    )
    |> TenantRepo.one()
  end

  @doc """
  The fields of a new charge of an account, as `SavingsAccountCharge`'s constructor makes them: `attrs` holds the
  `:amount` asked for (the definition's when `nil`), the `:due_date`, the `:month_day` (`{month, day}`) and the
  `:fee_interval`. Raises Fineract's error for a charge that falls due on a date it was given none of.
  """
  @spec build(map, map, non_neg_integer) :: map
  def build(definition, attrs, digits) do
    month_day = attrs[:month_day] || month_day_of(definition)
    time = definition.time
    missing_due_date!(definition, time, attrs[:due_date], month_day)

    {month, day} = fee_day(time, month_day, attrs[:due_date])
    interval = if time in [@monthly, @weekly], do: attrs[:fee_interval] || definition.fee_interval
    chosen = attrs[:amount] || definition.amount

    base = %{
      charge_id: definition.id,
      time: time,
      due_date: attrs[:due_date],
      fee_on_month: month,
      fee_on_day: day,
      fee_interval: interval,
      calculation: definition.calculation,
      penalty: definition.penalty == true,
      paid: nil,
      waived_amount: nil,
      written_off: nil,
      waived: false,
      is_active: true,
      inactivated_on_date: nil,
      free_withdrawal_count: 0,
      charge_reset_date: nil
    }

    derived(base, chosen, digits)
  end

  defp month_day_of(%{fee_on_month: month, fee_on_day: day})
       when not is_nil(month) and not is_nil(day),
       do: {month, day}

  defp month_day_of(_definition), do: nil

  defp missing_due_date!(definition, time, due_date, month_day) do
    missing? =
      (time == @specified and due_date == nil) or
        (time in [@annual, @monthly] and month_day == nil) or
        (time == @weekly and due_date == nil)

    if missing? do
      raise ECBPlatform.Errors.DomainRuleViolation,
        code: "error.msg.savingsaccount.charge.dueDate.cannot.be.blank",
        message: "Savings Account charge is missing due date.",
        args: [definition.id, definition.name]
    end
  end

  # the day a fee falls on: month and day for annual and monthly fees, the day of the week for a weekly one
  defp fee_day(time, {month, day}, _due_date) when time in [@annual, @monthly], do: {month, day}
  defp fee_day(@weekly, _month_day, due_date), do: {nil, Date.day_of_week(due_date)}
  defp fee_day(_time, _month_day, _due_date), do: {nil, nil}

  # the amounts a charge starts with, by how it is calculated
  defp derived(%{calculation: 1} = c, amount, digits) do
    flat = Decimal.round(amount, digits, :half_even)
    outstanding = if c.time in [@withdrawal_fee, @no_activity], do: Decimal.new(0), else: flat

    c
    |> Map.merge(%{percentage: nil, applied_to: nil, amount: flat, outstanding: outstanding})
    |> then(&Map.put(&1, :is_paid, fully_paid?(&1)))
  end

  defp derived(%{calculation: 2} = c, percentage, _digits) do
    c
    |> Map.merge(%{
      percentage: percentage,
      applied_to: Decimal.new(0),
      amount: Decimal.new(0),
      outstanding: Decimal.new(0)
    })
    |> then(&Map.put(&1, :is_paid, fully_paid?(&1)))
  end

  @doc "Stores a new charge of the account and answers with its id."
  @spec create!(struct, integer, map) :: integer
  def create!(user, account_id, c) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_savings_account_charge",
        [
          %{
            savings_account_id: account_id,
            charge_id: c.charge_id,
            is_penalty: c.penalty,
            charge_time_enum: c.time,
            charge_due_date: c.due_date,
            fee_on_month: c.fee_on_month,
            fee_on_day: c.fee_on_day,
            fee_interval: c.fee_interval,
            free_withdrawal_count: c.free_withdrawal_count,
            charge_calculation_enum: c.calculation,
            calculation_percentage: c.percentage,
            calculation_on_amount: c.applied_to,
            amount: c.amount,
            amount_outstanding_derived: c.outstanding,
            is_paid_derived: c.is_paid,
            waived: false,
            is_active: true,
            created_by: user.id,
            last_modified_by: user.id,
            created_on_utc: now,
            last_modified_on_utc: now
          }
        ],
        returning: [:id]
      )

    id
  end

  # --- writes ---------------------------------------------------------------------------------------

  @columns ~w(due_date fee_on_month fee_on_day fee_interval amount paid waived_amount outstanding is_paid waived is_active
              inactivated_on_date percentage applied_to free_withdrawal_count charge_reset_date)a

  @doc "Stores what a change left of a charge (its derived amounts, due date and state)."
  @spec save!(struct, map) :: :ok
  def save!(user, c) do
    set =
      for key <- @columns do
        {column(key), Map.get(c, key)}
      end

    set =
      set ++
        [
          last_modified_by: user.id,
          last_modified_on_utc: DateTime.utc_now()
        ]

    TenantRepo.update_all(from(x in "m_savings_account_charge", where: x.id == ^c.id), set: set)
    :ok
  end

  defp column(:due_date), do: :charge_due_date
  defp column(:paid), do: :amount_paid_derived
  defp column(:waived_amount), do: :amount_waived_derived
  defp column(:outstanding), do: :amount_outstanding_derived
  defp column(:is_paid), do: :is_paid_derived
  defp column(:percentage), do: :calculation_percentage
  defp column(:applied_to), do: :calculation_on_amount
  defp column(:charge_reset_date), do: :charge_reset_date
  defp column(key), do: key
end
