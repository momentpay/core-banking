defmodule ECBPlatform.Json do
  @moduledoc """
  Reads whole numbers from a request the way Fineract's `FromJsonHelper.extractLongNamed` does: the value
  is taken as text and parsed with `Long.valueOf`, so `"12"` and `12` are numbers, while `"x"`, `12.5`,
  `" 12"` and `true` are not, and a number that fails to parse is an unhandled failure there (a plain
  HTTP 500) rather than a validation error.
  """
  alias ECBPlatform.Params

  @doc "A whole number parameter, or `nil` when absent, null, blank or not a simple value."
  @spec long(Params.t(), String.t()) :: integer | nil
  def long(%Params{} = p, key), do: p |> Params.value(key) |> to_long()

  defp to_long(value) when is_integer(value), do: value
  defp to_long(value) when is_float(value), do: raise(ECBPlatform.Errors.ServerError)
  defp to_long(value) when is_boolean(value), do: raise(ECBPlatform.Errors.ServerError)

  defp to_long(value) when is_binary(value) do
    if String.trim(value) == "" do
      nil
    else
      case Integer.parse(value) do
        {number, ""} -> number
        _ -> raise ECBPlatform.Errors.ServerError
      end
    end
  end

  defp to_long(_other), do: nil
end
