defmodule ECBApiFineract.Response do
  @moduledoc """
  Writing JSON the way Fineract does.

    * Fields that are `nil` are left out, not sent as `null`.
    * A `Date` is an array `[year, month, day]` (`[2009, 1, 1]`), which is how Fineract serialises
      local dates.
    * A `Decimal` is a JSON number with its exact digits, never a string and never a float, so
      `12.50` stays `12.50`.
    * Keys are written as given: the caller builds the camelCase names Fineract uses.
  """
  import Plug.Conn

  @doc "Sends `body` as JSON with the given status."
  @spec json(Plug.Conn.t(), pos_integer, term) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body |> prepare() |> Jason.encode!())
  end

  @doc false
  def prepare(%Date{year: y, month: m, day: d}), do: [y, m, d]
  def prepare(%Decimal{} = decimal), do: Jason.Fragment.new(Decimal.to_string(decimal, :normal))

  def prepare(%{__struct__: _} = struct), do: struct

  def prepare(map) when is_map(map) do
    for {key, value} <- map, value != nil, into: %{}, do: {key, prepare(value)}
  end

  def prepare(list) when is_list(list), do: Enum.map(list, &prepare/1)
  def prepare(other), do: other
end
