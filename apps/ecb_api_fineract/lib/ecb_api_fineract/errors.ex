defmodule ECBApiFineract.Errors do
  @moduledoc """
  Error responses in the shapes Fineract sends.

  Two shapes exist and both are reproduced:

    * the **platform** error (`developerMessage`, `httpStatusCode`, `defaultUserMessage`,
      `userMessageGlobalisationCode`, and a list of `errors`) for application failures, and
    * the **Spring** error (`timestamp`, `status`, `error`, `path`) that the web container sends for a
      request rejected before it reaches the application: a missing tenant, or bad credentials.
  """
  import Plug.Conn

  alias ECBApiFineract.Response

  @realm ~s(Basic realm="Fineract Platform API")

  # --- platform errors ------------------------------------------------------------------------

  @doc "HTTP 401 for credentials that were wrong, as `/authentication` reports them."
  def unauthenticated(conn) do
    Response.json(conn, 401, %{
      "developerMessage" => "Invalid authentication details were passed in api request.",
      "httpStatusCode" => "401",
      "defaultUserMessage" => "Unauthenticated. Please login.",
      "userMessageGlobalisationCode" => "error.msg.not.authenticated"
    })
  end

  @doc "HTTP 403: authenticated, but without the permission. `message` is the reason, as Fineract words it."
  def not_authorized(conn, message) do
    code = "error.msg.not.authorized"

    Response.json(conn, 403, %{
      "developerMessage" =>
        "The user associated with credentials passed on this request does not have sufficient privileges to perform this action.",
      "httpStatusCode" => "403",
      "defaultUserMessage" => "Insufficient privileges to perform this action.",
      "userMessageGlobalisationCode" => code,
      "errors" => [parameter_error(code, message, message, "id", [])]
    })
  end

  @doc "HTTP 404 for a resource that does not exist. `code` is the specific message code, `args` the values to show."
  def not_found(conn, code, message, args) do
    generic = "The requested resource is not available."

    Response.json(conn, 404, %{
      "developerMessage" => generic,
      "httpStatusCode" => "404",
      "defaultUserMessage" => generic,
      "userMessageGlobalisationCode" => "error.msg.resource.not.found",
      "errors" => [parameter_error(code, message, message, "id", args)]
    })
  end

  @doc "HTTP 403 for a request that was understood but breaks a rule (for example an order field that is not allowed)."
  def domain_rule_violation(conn, code, message) do
    Response.json(conn, 403, %{
      "developerMessage" => "Request was understood but caused a domain rule violation.",
      "httpStatusCode" => "403",
      "defaultUserMessage" => "Errors contain reason for domain rule violation.",
      "userMessageGlobalisationCode" => "validation.msg.domain.rule.violation",
      "errors" => [parameter_error(code, message, message, "id", [])]
    })
  end

  @doc "HTTP 501 for an operation that is in Fineract's API but not built yet (or deliberately deferred)."
  def not_implemented(conn, method, path) do
    message = "#{method} #{path} is not implemented in E-CoreBank yet"

    Response.json(conn, 501, %{
      "developerMessage" => "Request was understood but not implemented.",
      "httpStatusCode" => "501",
      "defaultUserMessage" => "Errors contain reason for not implemented violation.",
      "userMessageGlobalisationCode" => "validation.msg.not.implemented",
      "errors" => [parameter_error("error.msg.not.implemented", message, message, "id", [])]
    })
  end

  defp parameter_error(code, developer_message, default_message, parameter, args) do
    %{
      "developerMessage" => developer_message,
      "defaultUserMessage" => default_message,
      "userMessageGlobalisationCode" => code,
      "parameterName" => parameter,
      "args" => Enum.map(args, &%{"value" => &1})
    }
  end

  # --- web-container errors -------------------------------------------------------------------

  @doc """
  The error Fineract's web container sends for a request that fails before the application sees it:
  400 for a missing or unknown tenant, 401 for wrong credentials.
  """
  def spring(conn, status, reason) do
    conn
    |> put_resp_header(
      "www-authenticate",
      if(status == 401, do: @realm <> ~s(, charset="UTF-8"), else: @realm)
    )
    |> Response.json(status, %{
      "timestamp" =>
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "status" => status,
      "error" => reason,
      "path" => conn.request_path
    })
  end

  @doc "HTTP 401 with no body, sent when no credentials were given at all."
  def challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", @realm <> ~s(, charset="UTF-8"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, "")
  end

  @doc "Sends the right response for an error returned by a domain module."
  @spec render(Plug.Conn.t(), Exception.t()) :: Plug.Conn.t()
  def render(conn, %ECBOrg.Errors.OfficeNotFound{office_id: id} = error),
    do: not_found(conn, "error.msg.office.id.invalid", Exception.message(error), [id])

  def render(conn, %ECBPlatform.Errors.ResourceNotFound{} = error),
    do: not_found(conn, error.code, error.message, error.args)

  def render(conn, %ECBOrg.Errors.InvalidOrdering{} = error),
    do:
      domain_rule_violation(
        conn,
        "error.msg.input.validation",
        "Input validation error: " <> Exception.message(error)
      )

  def render(conn, %ECBPlatform.Commands.Errors.NoAuthorization{} = error),
    do: not_authorized(conn, Exception.message(error))

  def render(conn, %ECBPlatform.Commands.Errors.RollbackNotApproved{} = error) do
    Response.json(conn, 202, %{"commandId" => error.command_id, "resourceId" => error.resource_id})
  end

  def render(conn, error) do
    require Logger
    Logger.error("unhandled API error: #{Exception.format(:error, error)}")

    Response.json(conn, 500, %{
      "developerMessage" => "An unexpected error occurred.",
      "httpStatusCode" => "500",
      "defaultUserMessage" => "An unexpected error occurred.",
      "userMessageGlobalisationCode" => "error.msg.platform.service.unexpected.error"
    })
  end
end
