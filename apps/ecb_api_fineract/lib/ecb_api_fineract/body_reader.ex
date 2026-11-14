defmodule ECBApiFineract.BodyReader do
  @moduledoc """
  Keeps the request body exactly as received, next to the parsed form.

  Commands store their JSON as text and compare it as text (to spot an identical pending command), so
  the raw body must survive `Plug.Parsers`. Pass this module as `Plug.Parsers`' `:body_reader`; the
  text is then in `conn.assigns.raw_body`.
  """

  @doc false
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)}

      {:more, body, conn} ->
        {:more, body, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)}

      other ->
        other
    end
  end
end
