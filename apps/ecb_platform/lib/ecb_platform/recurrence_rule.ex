defmodule ECBPlatform.RecurrenceRule do
  @moduledoc """
  iCalendar recurrence rules (RFC 5545), as stored for the working week
  (`FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR`) and later for meetings and schedules.

  `validate/1` checks that a rule is well formed. `working_day?/2` answers whether a date falls on one
  of the days a weekly rule names. Only what the platform needs is understood: the frequency, interval,
  count, until and the by-parts are checked for form, and weekly `BYDAY` rules can be evaluated.
  """

  @frequencies ~w(SECONDLY MINUTELY HOURLY DAILY WEEKLY MONTHLY YEARLY)
  @days ~w(SU MO TU WE TH FR SA)
  @known_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY BYMONTHDAY BYMONTH BYSETPOS BYYEARDAY BYWEEKNO BYHOUR BYMINUTE BYSECOND WKST)

  @doc """
  `:ok` for a well-formed rule. `{:error, :parse, detail}` when the text cannot be read as a rule, and
  `{:error, :invalid}` when it reads but is not a usable rule (no frequency).
  """
  @spec validate(String.t()) :: :ok | {:error, :parse, String.t()} | {:error, :invalid}
  def validate(rule) when is_binary(rule) do
    with {:ok, parts} <- parse(rule),
         :ok <- check_parts(parts) do
      if Map.has_key?(parts, "FREQ"), do: :ok, else: {:error, :invalid}
    end
  end

  @doc "True when `date` is on one of the weekdays named by the rule's `BYDAY` (every day when it names none)."
  @spec working_day?(String.t(), Date.t()) :: boolean
  def working_day?(rule, %Date{} = date) do
    case parse(rule) do
      {:ok, %{"BYDAY" => days}} ->
        names = days |> String.split(",", trim: true) |> Enum.map(&String.slice(&1, -2, 2))
        Enum.at(@days, rem(Date.day_of_week(date), 7)) in names

      _ ->
        true
    end
  end

  # --- parsing --------------------------------------------------------------------------------

  defp parse(rule) do
    rule
    |> String.trim()
    |> String.split(";", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        [key, value] when value != "" -> {:cont, {:ok, Map.put(acc, String.upcase(key), value)}}
        _ -> {:halt, {:error, :parse, "Missing expected token, last token: #{part}"}}
      end
    end)
    |> case do
      {:ok, parts} when map_size(parts) == 0 ->
        {:error, :parse, "Missing expected token, last token: #{rule}"}

      other ->
        other
    end
  end

  defp check_parts(parts) do
    Enum.find_value(parts, :ok, fn {key, value} ->
      case check(key, value) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp check("FREQ", value) do
    if String.upcase(value) in @frequencies,
      do: :ok,
      else: {:error, :parse, "No enum constant Recur.Frequency.#{value}"}
  end

  defp check(key, value) when key in ~w(INTERVAL COUNT) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> :ok
      _ -> {:error, :parse, "For input string: \"#{value}\""}
    end
  end

  defp check("BYDAY", value) do
    value
    |> String.split(",", trim: true)
    |> Enum.find_value(:ok, fn day ->
      name = String.upcase(String.slice(day, -2, 2))
      if name in @days, do: nil, else: {:error, :parse, "No enum constant WeekDay.Day.#{name}"}
    end)
  end

  defp check(key, _value) when key in @known_parts, do: :ok
  defp check(key, _value), do: {:error, :parse, "Unknown rule part #{key}"}
end
