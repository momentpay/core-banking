defmodule ECBPlatform.Cron do
  @moduledoc """
  Quartz cron expressions, the kind the scheduler jobs carry (`0 1 0 1/1 * ? *`): seconds, minutes, hours,
  day of month, month, day of week and (optionally) year.

  Understood in each field: `*`, `?`, a number, a range `a-b`, a step `a/n` or `*/n`, a range with a step
  `a-b/n`, and lists of these with `,`. Months and weekdays may be named (`JAN`, `MON`); the weekdays count from
  Sunday = 1, as in Quartz. The special forms `L`, `W`, `#` and `C` are refused. Times are UTC.
  """

  defstruct [:seconds, :minutes, :hours, :days, :months, :weekdays, :years]

  @type t :: %__MODULE__{}

  @months ~w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
  @weekdays ~w(SUN MON TUE WED THU FRI SAT)

  @doc "Parses `expression`, or raises `ArgumentError`."
  @spec parse!(String.t()) :: t
  def parse!(expression) when is_binary(expression) do
    fields = String.split(expression)

    unless length(fields) in [6, 7],
      do:
        raise(ArgumentError, "a cron expression has six or seven fields: #{inspect(expression)}")

    [sec, min, hour, dom, month, dow | year] = fields

    %__MODULE__{
      seconds: field!(sec, 0..59),
      minutes: field!(min, 0..59),
      hours: field!(hour, 0..23),
      days: field!(dom, 1..31),
      months: field!(translate(month, @months, 1), 1..12),
      weekdays: field!(translate(dow, @weekdays, 1), 1..7),
      years: year |> List.first("*") |> field!(1970..2199)
    }
  end

  @doc "Whether `expression` can be parsed."
  @spec valid?(String.t()) :: boolean
  def valid?(expression) do
    parse!(expression)
    true
  rescue
    ArgumentError -> false
  end

  @doc """
  The first time after `from` (whole seconds) that `expression` fires, or `nil` if it never does in the next
  few years.
  """
  @spec next(String.t() | t, NaiveDateTime.t()) :: NaiveDateTime.t() | nil
  def next(expression, from) when is_binary(expression), do: next(parse!(expression), from)

  def next(%__MODULE__{} = cron, %NaiveDateTime{} = from) do
    start = from |> NaiveDateTime.truncate(:second) |> NaiveDateTime.add(1)
    first = NaiveDateTime.to_date(start)
    search(cron, first, start, Date.add(first, 366 * 8))
  end

  defp search(cron, date, start, last) do
    cond do
      Date.compare(date, last) == :gt ->
        nil

      day?(cron, date) ->
        case first_time(cron, date, start) do
          nil -> search(cron, Date.add(date, 1), start, last)
          time -> time
        end

      true ->
        search(cron, Date.add(date, 1), start, last)
    end
  end

  defp first_time(cron, date, start) do
    cron.hours
    |> Stream.flat_map(&minutes_of(cron, &1))
    |> Stream.map(fn {h, m, s} -> NaiveDateTime.new!(date, Time.new!(h, m, s)) end)
    |> Enum.find(&(NaiveDateTime.compare(&1, start) != :lt))
  end

  defp minutes_of(cron, hour), do: Stream.flat_map(cron.minutes, &seconds_of(cron, hour, &1))
  defp seconds_of(cron, hour, minute), do: Stream.map(cron.seconds, &{hour, minute, &1})

  defp day?(cron, date) do
    date.year in cron.years and date.month in cron.months and date.day in cron.days and
      weekday(date) in cron.weekdays
  end

  # Quartz counts the weekdays from Sunday = 1
  defp weekday(date), do: rem(Date.day_of_week(date), 7) + 1

  defp translate(field, names, first) do
    names
    |> Enum.with_index(first)
    |> Enum.reduce(String.upcase(field), fn {name, number}, acc ->
      String.replace(acc, name, Integer.to_string(number))
    end)
  end

  # `*` and `?` are every value; the rest is a list of numbers, ranges and steps
  defp field!(text, range) when text in ["*", "?"], do: Enum.to_list(range)

  defp field!(text, range) do
    text
    |> String.split(",")
    |> Enum.flat_map(&part!(&1, range))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp part!(part, range) do
    {base, step} = split_step(part)
    {from, to} = bounds(base, step, range, part)

    unless from in range and to in range and from <= to and (step || 1) > 0,
      do: raise(ArgumentError, "cron value out of range: #{inspect(part)}")

    Enum.take_every(from..to, step || 1)
  end

  # `a-b/n` is the range `a-b` and the step `n`
  defp split_step(part) do
    case String.split(part, "/") do
      [base] -> {base, nil}
      [base, step] -> {base, integer!(step, part)}
      _ -> raise ArgumentError, "invalid cron field #{inspect(part)}"
    end
  end

  # the first and last value of a range, where a lone value with a step runs to the end of the field
  defp bounds(base, step, first..last//_, part) do
    case String.split(base, "-") do
      ["*"] -> {first, last}
      [value] when is_nil(step) -> {integer!(value, part), integer!(value, part)}
      [value] -> {integer!(value, part), last}
      [from, to] -> {integer!(from, part), integer!(to, part)}
      _ -> raise ArgumentError, "invalid cron field #{inspect(part)}"
    end
  end

  defp integer!(text, part) do
    case Integer.parse(text) do
      {number, ""} -> number
      _ -> raise ArgumentError, "invalid cron field #{inspect(part)}"
    end
  end
end
