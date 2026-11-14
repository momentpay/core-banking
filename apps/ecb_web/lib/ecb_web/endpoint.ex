defmodule ECBWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ecb_web

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_ecb_web_key",
    signing_salt: "3VV41hZ9",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :ecb_web,
    gzip: false,
    only: ECBWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :ecb_platform
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  @parser_options Plug.Parsers.init(
                    parsers: [:urlencoded, :multipart, :json],
                    pass: ["*/*"],
                    json_decoder: Phoenix.json_library(),
                    # keep the request body as received: commands store their JSON as text
                    body_reader: {ECBApiFineract.BodyReader, :read_body, []}
                  )

  plug :parse_body

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ECBWeb.Router

  # The compatible API reads its own bodies (and answers a body that is not JSON in Fineract's way), so
  # the requests for it are left alone here.
  defp parse_body(%Plug.Conn{path_info: ["fineract-provider" | _]} = conn, _opts), do: conn
  defp parse_body(conn, _opts), do: Plug.Parsers.call(conn, @parser_options)
end
