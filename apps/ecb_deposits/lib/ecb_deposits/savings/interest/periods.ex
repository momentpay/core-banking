defmodule ECBDeposits.Savings.Interest.Periods do
  @moduledoc """
  The periods interest is worked out and posted over, after Fineract's `SavingsHelper.determineInterestPostingPeriods`
  and the compounding-period rules of `PostingPeriod`. A posting period ends the day before interest is posted (or
  on the day, with the configuration that says so); a posting period holds one compounding period when interest
  compounds daily, and one per month, quarter, half year or year otherwise.

  Posting types: 1 daily, 4 monthly, 5 quarterly, 6 biannual, 7 annual and 8 to 11 their anniversary forms (from the
  day of the month the account began earning). Compounding types: 1 daily, 4 monthly, 5 quarterly, 6 biannual,
  7 annual.
  """

  @type interval :: {Date.t(), Date.t()}

  # --- posting periods --------------------------------------------------------------------------

  @doc """
  The posting periods from `start` to `up_to`, as `[{from, to}]`. A date in `as_on` splits the period it falls in
  and ends it the day before (a manual posting).
  """
  @spec posting_periods(Date.t() | nil, Date.t() | nil, integer | nil, integer, [Date.t()]) ::
          [interval]
  def posting_periods(nil, _up_to, _type, _fy, _as_on), do: []
  def posting_periods(_start, nil, _type, _fy, _as_on), do: []
  def posting_periods(_start, _up_to, nil, _fy, _as_on), do: []

  def posting_periods(start, up_to, type, fy_begin, as_on),
    do: loop(start, start, start, {start.day, up_to, type, fy_begin, as_on}, [])

  defp loop(from, to, actual, {anniversary, up_to, type, fy, as_on} = ctx, acc) do
    if after?(from, up_to) or after?(to, up_to) do
      Enum.reverse(acc)
    else
      posting = posting_end(from, type, up_to, fy, anniversary)
      ended = Date.add(posting, -1)

      {ended, actual} =
        case Enum.find(as_on, &(after?(&1, from) and not after?(&1, ended))) do
          nil ->
            {ended, actual}

          date ->
            day = Date.add(date, -1)
            {day, day}
        end

      acc = [{from, ended} | acc]

      if Date.compare(actual, ended) == :eq do
        next = Date.add(actual, 1)
        loop(next, next, actual, ctx, acc)
      else
        loop(posting, posting, actual, ctx, acc)
      end
    end
  end

  # the day interest is posted: the day after the period ends
  defp posting_end(from, type, up_to, fy_begin, anniversary) do
    fy = fy_end_month(fy_begin)

    case type do
      1 -> Date.add(from, 1)
      4 -> from |> Date.end_of_month() |> Date.add(1)
      5 -> next_month_end(from, fy, 3, 4)
      6 -> next_month_end(from, fy, 6, 2)
      7 -> annual_end(from, fy)
      _ -> anniversary_end(from, type, up_to, anniversary)
    end
  end

  # the anniversary forms: a month, a quarter, half a year or a year on, on the day of the month the account began
  defp anniversary_end(from, type, up_to, anniversary) do
    case type do
      8 -> anniversary_day(Date.shift(from, month: 1), anniversary)
      9 -> anniversary_day(Date.shift(from, month: 3), anniversary)
      10 -> anniversary_day(Date.shift(from, month: 6), anniversary)
      11 -> anniversary_day(Date.shift(from, month: 12), anniversary)
      _ -> Date.add(up_to, 1)
    end
  end

  # the month the financial year ends in
  defp fy_end_month(begin), do: if(begin - 1 == 0, do: 12, else: begin - 1)

  # the end of the first quarter (or half) that finishes after `from`, plus a day; the first of next year's when
  # none does
  defp next_month_end(from, fy, step, count) do
    ends =
      0..(count - 1)
      |> Enum.map(fn k -> month_end(from.year, rem(fy - 1 + step * k, 12) + 1) end)
      |> Enum.sort(Date)

    case Enum.find(ends, &after?(&1, from)) do
      nil -> ends |> hd() |> Date.shift(year: 1) |> Date.end_of_month() |> Date.add(1)
      date -> Date.add(date, 1)
    end
  end

  defp annual_end(from, fy) do
    ended = with_month(from, fy)
    ended = if fy < from.month, do: Date.shift(ended, year: 1), else: ended
    ended |> Date.end_of_month() |> Date.add(1)
  end

  defp anniversary_day(date, day),
    do: %{date | day: min(day, Date.days_in_month(date))}

  defp month_end(year, month), do: year |> Date.new!(month, 1) |> Date.end_of_month()

  defp with_month(date, month) do
    first = Date.new!(date.year, month, 1)
    %{first | day: min(date.day, Date.days_in_month(first))}
  end

  # --- compounding periods ----------------------------------------------------------------------

  @doc """
  The compounding periods inside the posting period `{from, to}`: one for daily compounding, else one per month,
  quarter, half year or year that lies wholly inside it. `business_date` is the date Fineract takes the length of
  the closing months of a quarter or half year from.
  """
  @spec compounding_periods(interval, integer, integer, Date.t()) :: [interval]
  def compounding_periods({from, to}, 1, _fy, _business_date), do: [{from, to}]

  def compounding_periods({from, to} = posting, type, fy, business_date),
    do: compound_loop(from, from, to, posting, {type, fy, business_date}, [])

  defp compound_loop(from, ended, to, posting, {type, fy, bd} = ctx, acc) do
    if after?(from, to) or after?(ended, to) do
      Enum.reverse(acc)
    else
      ended = min_date(compounding_end(from, type, fy, bd), to)
      acc = if inside?(posting, {from, ended}), do: [{from, ended} | acc], else: acc
      compound_loop(Date.add(ended, 1), ended, to, posting, ctx, acc)
    end
  end

  @doc "The end of the compounding period that begins on `from`."
  @spec compounding_end(Date.t(), integer, integer, Date.t()) :: Date.t()
  def compounding_end(from, type, fy_begin, business_date) do
    fy = fy_end_month(fy_begin)

    case type do
      1 -> from
      4 -> Date.end_of_month(from)
      5 -> period_end(fy, 4, from, business_date)
      6 -> period_end(fy, 2, from, business_date)
      7 -> annual_compounding_end(from, fy)
      _ -> from
    end
  end

  defp annual_compounding_end(from, fy) do
    ended = from |> with_month(fy) |> Date.end_of_month()
    if Date.compare(ended, from) == :lt, do: Date.shift(ended, year: 1), else: ended
  end

  # the first of the months (`count` of them, a year apart from each other in equal steps, beginning with `fy`)
  # that has not passed; its length is that of the month in the year of the business date
  defp period_end(fy, count, from, business_date) do
    months =
      0..(count - 1)
      |> Enum.map(&(rem(fy - 1 + &1 * div(12, count), 12) + 1))
      |> Enum.sort()

    case Enum.find(months, &(from.month <= &1)) do
      nil ->
        month = hd(months)
        Date.new!(from.year + 1, month, length_of_month(business_date.year, month))

      month ->
        Date.new!(from.year, month, length_of_month(business_date.year, month))
    end
  end

  defp length_of_month(year, month), do: Date.days_in_month(Date.new!(year, month, 1))

  # --- dates --------------------------------------------------------------------------------------

  defp after?(a, b), do: Date.compare(a, b) == :gt
  defp min_date(a, b), do: if(after?(a, b), do: b, else: a)

  defp inside?({from, to}, {a, b}),
    do: Date.compare(a, from) != :lt and Date.compare(b, to) != :gt
end
