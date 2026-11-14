defmodule ECBApiFineract.Resources.Read do
  @moduledoc """
  The shape every read endpoint shares: check the user may read the resource (`READ_<RESOURCE>`), build
  the answer, send it as JSON, or turn a domain error into Fineract's error response.

  The function passed in returns the body to send, or `{:error, exception}`.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBPlatform.Security

  @doc "Sends `fun.()` as the 200 response when the current user may read `resource`."
  @spec respond(Plug.Conn.t(), String.t(), (-> term)) :: Plug.Conn.t()
  def respond(conn, resource, fun) do
    with :ok <- Security.validate_has_read_permission(conn.assigns.current_user, resource),
         body when not is_tuple(body) <- build(fun) do
      Response.json(conn, 200, body)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  # What the function raises about the request (a bad date, say) is answered, not crashed on.
  defp build(fun) do
    fun.()
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: {:error, error},
        else: reraise(error, __STACKTRACE__)
  end

  @doc "A `{id, code, value}` option as Fineract's `EnumOptionData`."
  @spec option(map) :: map
  def option(%{id: id, code: code, value: value}),
    do: %{"id" => id, "code" => code, "value" => value}

  @doc "Parses a query parameter as an integer; `nil` when absent or not a number."
  @spec int_param(map, String.t()) :: integer | nil
  def int_param(params, name) do
    case Integer.parse(to_string(params[name])) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
