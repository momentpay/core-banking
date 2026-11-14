defmodule ECBPlatform.Params.DatePattern do
  @moduledoc """
  Reads dates written to a Java `DateTimeFormatter` pattern, as API clients send them
  (`dd MMMM yyyy`, `yyyy-MM-dd`, `dd/MM/yy`, ...).

  Follows how Fineract configures its parser: case-insensitive, lenient about digit counts (`1 March`
  matches `dd MMMM`), a month name may be written in full or abbreviated whichever the pattern says,
  an optional ` HH:mm:ss` may follow, and the date itself is checked strictly (30 February is
  refused). Month names are English only for now; other locales are a known gap.

  Understood pattern letters: `d`, `M`, `y`/`u`, and the literal characters around them; text inside
  single quotes is literal. Any other letter makes the pattern unusable and every value fails.
  """

  @months ~w(january february march april may june july august september october november december)

  @doc "Parses `text` against `pattern`: `{:ok, date}` or `:error`."
  @spec parse(String.t(), String.t()) :: {:ok, Date.t()} | :error
  def parse(text, pattern) when is_binary(text) and is_binary(pattern) do
    with {:ok, tokens} <- tokenize(pattern),
         {:ok, regex} <- to_regex(tokens),
         [_ | captures] <- Regex.run(regex, String.trim(text), capture: :all),
         {:ok, fields} <- extract(tokens, captures) do
      build(fields)
    else
      _ -> :error
    end
  end

  # --- pattern -> tokens ----------------------------------------------------------------------

  defp tokenize(pattern), do: tokenize(String.to_charlist(pattern), [])

  defp tokenize([], acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize([?' | rest], acc) do
    {quoted, remaining} = Enum.split_while(rest, &(&1 != ?'))
    tokenize(Enum.drop(remaining, 1), [{:literal, List.to_string(quoted)} | acc])
  end

  defp tokenize([letter | _] = chars, acc) when letter in [?d, ?M, ?y, ?u] do
    {run, rest} = Enum.split_while(chars, &(&1 == letter))
    tokenize(rest, [{field(letter), length(run)} | acc])
  end

  defp tokenize([letter | _], _acc) when letter in ?a..?z or letter in ?A..?Z, do: :error
  defp tokenize([char | rest], acc), do: tokenize(rest, [{:literal, <<char::utf8>>} | acc])

  defp field(?d), do: :day
  defp field(?M), do: :month
  defp field(letter) when letter in [?y, ?u], do: :year

  # --- tokens -> regex ------------------------------------------------------------------------

  defp to_regex(tokens) do
    body = Enum.map_join(tokens, &regex_for/1)
    Regex.compile("^" <> body <> "(?: \\d{1,2}:\\d{2}:\\d{2})?$", "i")
  end

  defp regex_for({:literal, text}), do: Regex.escape(text)
  defp regex_for({:day, _}), do: "(\\d{1,2})"
  defp regex_for({:month, width}) when width >= 3, do: "([[:alpha:]]+)"
  defp regex_for({:month, _}), do: "(\\d{1,2})"
  defp regex_for({:year, 2}), do: "(\\d{2})"
  defp regex_for({:year, _}), do: "(\\d{1,9})"

  # --- values ---------------------------------------------------------------------------------

  defp extract(tokens, captures) do
    fields = Enum.reject(tokens, &match?({:literal, _}, &1))

    if length(fields) == length(captures) do
      fields |> Enum.zip(captures) |> Enum.reduce_while({:ok, %{}}, &add_field/2)
    else
      :error
    end
  end

  defp add_field({{name, width}, text}, {:ok, acc}) do
    case value(name, width, text) do
      {:ok, number} -> {:cont, {:ok, Map.put(acc, name, number)}}
      :error -> {:halt, :error}
    end
  end

  defp value(:month, width, text) when width >= 3, do: month_by_name(text)
  defp value(:year, 2, text), do: {:ok, 2000 + String.to_integer(text)}
  defp value(_name, _width, text), do: {:ok, String.to_integer(text)}

  defp month_by_name(text) do
    name = String.downcase(text)

    @months
    |> Enum.with_index(1)
    |> Enum.find(fn {month, _} -> name == month or name == String.slice(month, 0, 3) end)
    |> case do
      {_, number} -> {:ok, number}
      nil -> :error
    end
  end

  defp build(%{day: day, month: month, year: year}) do
    case Date.new(year, month, day) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp build(_missing_a_field), do: :error
end
