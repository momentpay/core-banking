defmodule ECBLoans.Schedule.Calendar do
  @moduledoc """
  What the working week and the holidays do to a schedule, following Fineract's `DefaultScheduledDateGenerator`
  (`adjustRepaymentDate` and the helpers under it), `WorkingDaysUtil` and `HolidayUtil`.

  A due date that falls on a non-working day moves according to the tenant's rule: to the next working day (2), to
  the next repayment date that is a working day (3) or to the previous working day (4); "same day" (1) leaves it where
  it is (Fineract's own loop does not end for it, so it is not copied). A due date inside a holiday of the loan's
  office moves, when holidays are switched on (`reschedule-repayments-on-holidays`), to the date the holiday names or to
  the next repayment date. The repayments after a date that moved to the next repayment date follow the new cadence.

  The calendar is built once for a loan (`load/2`) and is `nil` when nothing can move a date (every day of the week
  works and no holiday applies), which is the case for a tenant as it is first set up.
  """
  alias ECBLoans.Schedule.Dates
  alias ECBPlatform.Configuration

  @type t :: %{
          days: MapSet.t(),
          seven_days?: boolean,
          type: 1..4,
          extend_daily?: boolean,
          holidays_on?: boolean,
          holidays: [map],
          first_on_holiday?: boolean
        }

  @weekdays %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}

  @doc """
  The calendar of a loan of `office_id` disbursed on `disbursement`: the working week, and the active holidays of the
  office that end on or after the disbursement. `nil` when nothing can move a due date.
  """
  @spec load(integer | nil, Date.t()) :: t | nil
  def load(office_id, disbursement) do
    week = ECBOrg.WorkingDays.get()
    days = working_days(week)
    holidays_on? = Configuration.enabled?("reschedule-repayments-on-holidays")

    holidays =
      if holidays_on? and office_id,
        do: ECBOrg.Holidays.active_from(office_id, disbursement),
        else: []

    if MapSet.size(days) == 7 and holidays == [] do
      nil
    else
      %{
        days: days,
        seven_days?: MapSet.size(days) == 7,
        type: (week && week.type_id) || 1,
        extend_daily?: (week && week.extend_term_for_daily_repayments) == true,
        holidays_on?: holidays_on?,
        holidays: holidays,
        first_on_holiday?:
          Configuration.enabled?("loan-reschedule-is-first-payday-allowed-on-holiday")
      }
    end
  end

  defp working_days(%{recurrence: recurrence}) when is_binary(recurrence) do
    case Regex.run(~r/BYDAY=([A-Z,]+)/, recurrence) do
      [_, list] ->
        list |> String.split(",") |> Enum.flat_map(&List.wrap(@weekdays[&1])) |> MapSet.new()

      _ ->
        MapSet.new(1..7)
    end
  end

  defp working_days(_), do: MapSet.new(1..7)

  @doc """
  Refuses a payment dated on a holiday of the loan's office, or on a day the tenant does not work, unless the
  tenant allows transactions on those days (`allow-transactions-on-holiday`, `allow-transactions-on-non-workingday`).
  The holiday is looked for first, as Fineract does.
  """
  @spec check_payment_date!(integer | nil, Date.t(), Date.t()) :: :ok
  def check_payment_date!(office_id, disbursed_on, on) do
    holidays = if office_id, do: ECBOrg.Holidays.active_from(office_id, disbursed_on), else: []

    in_holiday =
      Enum.any?(
        holidays,
        &(Date.compare(on, &1.from_date) != :lt and Date.compare(on, &1.to_date) != :gt)
      )

    if in_holiday and not Configuration.enabled?("allow-transactions-on-holiday"),
      do: refuse!("repayment.date.on.holiday", "Repayment date cannot be on a holiday", on)

    week = ECBOrg.WorkingDays.get()

    if not MapSet.member?(working_days(week), Date.day_of_week(on)) and
         not Configuration.enabled?("allow-transactions-on-non-workingday"),
       do:
         refuse!(
           "repayment.date.on.non.working.day",
           "Repayment date cannot be on a non working day",
           on
         )

    :ok
  end

  @doc """
  Refuses paying out a loan whose expected disbursement date is on a non-working day or a holiday, unless the tenant
  allows transactions on such days.
  """
  @spec check_disbursement_date!(integer | nil, Date.t()) :: :ok
  def check_disbursement_date!(office_id, expected) do
    holidays = if office_id, do: ECBOrg.Holidays.active_from(office_id, expected), else: []

    if not MapSet.member?(working_days(ECBOrg.WorkingDays.get()), Date.day_of_week(expected)) and
         not Configuration.enabled?("allow-transactions-on-non-workingday"),
       do:
         refuse!(
           "disbursement.date.on.non.working.day",
           "Expected disbursement date cannot be on a non working day",
           expected
         )

    in_holiday =
      Enum.any?(
        holidays,
        &(Date.compare(expected, &1.from_date) != :lt and
            Date.compare(expected, &1.to_date) != :gt)
      )

    if in_holiday and not Configuration.enabled?("allow-transactions-on-holiday"),
      do:
        refuse!(
          "disbursement.date.on.holiday",
          "Expected disbursement date cannot be on a holiday",
          expected
        )

    :ok
  end

  defp refuse!(code, message, on) do
    raise ECBPlatform.Errors.DomainRuleViolation,
      code: "error.msg.loan.application." <> code,
      message: message,
      args: [Date.to_iso8601(on)]
  end

  @doc "Whether `date` is a working day of the week (every day when there is no calendar)."
  @spec working_day?(t | nil, Date.t()) :: boolean
  def working_day?(nil, _date), do: true
  def working_day?(cal, date), do: MapSet.member?(cal.days, Date.day_of_week(date))

  @doc "The holiday `date` falls in, or `nil`."
  @spec holiday(t | nil, Date.t()) :: map | nil
  def holiday(nil, _date), do: nil

  def holiday(cal, date),
    do:
      Enum.find(
        cal.holidays,
        &(Date.compare(date, &1.from_date) != :lt and Date.compare(date, &1.to_date) != :gt)
      )

  @doc """
  The date the schedule keeps as its due date for the repayment that would fall on `raw`, and the date it counts the
  following repayments from (the two differ when a repayment moved to the next repayment date does not move the ones
  after it): `{due, actual}`.
  """
  @spec adjust(t | nil, Date.t(), map) :: {Date.t(), Date.t()}
  def adjust(nil, raw, _terms), do: {raw, raw}

  def adjust(cal, raw, terms) do
    cal = if daily_extension?(cal, terms), do: %{cal | type: 2}, else: cal
    next = Dates.next_repayment_date(raw, terms, false)
    adjusted = settle(cal, terms, %{schedule: raw, actual: raw, next: next})
    {adjusted.schedule, adjusted.actual}
  end

  @doc "Whether daily repayments follow the working days instead of the calendar (the term is extended)."
  @spec daily_extension?(t | nil, map) :: boolean
  def daily_extension?(nil, _terms), do: false

  def daily_extension?(cal, terms),
    do: cal.extend_daily? and terms.repayment_frequency == 0 and terms.repayment_every == 1

  # Fineract's `recursivelyCheckNonWorkingDaysAndHolidays...`: the checks run again while the date is still on a
  # holiday or a non-working day
  defp settle(cal, terms, adjusted) do
    adjusted =
      if cal.seven_days?, do: adjusted, else: move_off_non_working_days(cal, terms, adjusted)

    adjusted = if cal.holidays_on?, do: move_off_holidays(cal, terms, adjusted), else: adjusted

    if still_blocked?(cal, adjusted.schedule),
      do: settle(cal, terms, adjusted),
      else: adjusted
  end

  # the "same day" rule leaves a date where it is: it never counts as blocked
  defp still_blocked?(cal, date) do
    (cal.holidays_on? and holiday(cal, date) != nil) or
      (cal.type != 1 and not working_day?(cal, date))
  end

  defp move_off_non_working_days(%{type: 1}, _terms, adjusted), do: adjusted

  defp move_off_non_working_days(cal, terms, adjusted) do
    if working_day?(cal, adjusted.schedule) do
      adjusted
    else
      adjusted = if cal.type == 3, do: next_repayment_day(cal, terms, adjusted), else: adjusted
      move_off_non_working_days(cal, terms, %{adjusted | schedule: offset(cal, adjusted)})
    end
  end

  # the next repayment date that is a working day and not before the date being moved
  defp next_repayment_day(cal, terms, adjusted) do
    next = skip_to_working_repayment(cal, terms, adjusted.next, adjusted.schedule)
    %{adjusted | next: next}
  end

  defp skip_to_working_repayment(cal, terms, next, schedule) do
    if not working_day?(cal, next) or Date.compare(schedule, next) == :gt,
      do:
        skip_to_working_repayment(
          cal,
          terms,
          Dates.next_repayment_date(next, terms, false),
          schedule
        ),
      else: next
  end

  defp offset(cal, %{schedule: date} = adjusted) do
    if working_day?(cal, date) do
      date
    else
      case cal.type do
        2 -> offset(cal, %{adjusted | schedule: Date.add(date, 1)})
        3 -> adjusted.next
        4 -> offset(cal, %{adjusted | schedule: Date.add(date, -1)})
        _ -> date
      end
    end
  end

  defp move_off_holidays(cal, terms, adjusted) do
    case holiday(cal, adjusted.schedule) do
      nil ->
        adjusted

      %{rescheduling_type: 1} ->
        move_off_holidays(cal, terms, to_next_repayment(terms, adjusted))

      %{rescheduling_type: 2, repayments_rescheduled_to: to} when to != nil ->
        if to == adjusted.schedule,
          do: adjusted,
          else: move_off_holidays(cal, terms, %{adjusted | schedule: to})

      _ ->
        adjusted
    end
  end

  # a holiday that moves repayments to the next repayment date moves the cadence with it
  defp to_next_repayment(terms, adjusted) do
    next = repayment_after(terms, adjusted.actual, adjusted.schedule)
    %{adjusted | schedule: next, next: next, actual: next}
  end

  defp repayment_after(terms, from, schedule) do
    if Date.compare(from, schedule) == :gt,
      do: from,
      else: repayment_after(terms, Dates.next_repayment_date(from, terms, false), schedule)
  end

  @doc """
  The date of the last repayment once the calendar has moved it (Fineract moves only that one when it works out the
  end of the loan).
  """
  @spec last_repayment_date(t | nil, map) :: Date.t()
  def last_repayment_date(cal, terms) do
    {due, _actual} = adjust(cal, Dates.last_repayment_date(terms), terms)
    due
  end
end
