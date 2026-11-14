defmodule ECBPlatform.Commands.Errors do
  @moduledoc """
  The errors the command pipeline returns, each with the HTTP status Fineract answers with.

  The pipeline returns `{:error, exception}` rather than raising, so a caller (the API layer, a job)
  decides what to do. `http_status/1` and `error_code/1` give the values for a response and for the
  `result_status_code` stored with the command.
  """

  defmodule NoAuthorization do
    @moduledoc "The user lacks the permission for the command. HTTP 403."
    defexception [:permission, :message]

    @impl true
    def exception(opts) do
      %__MODULE__{
        permission: Keyword.fetch!(opts, :permission),
        message: Keyword.get(opts, :message)
      }
    end

    @impl true
    def message(%{message: nil, permission: permission}),
      do: "User has no authority to: #{permission}"

    def message(%{message: message}), do: message
  end

  defmodule PermissionNotFound do
    @moduledoc "A permission code that does not exist. HTTP 404."
    defexception [:code]

    @impl true
    def message(%{code: code}), do: "Permission with code #{inspect(code)} does not exist"
  end

  defmodule CheckerOnlyInitiation do
    @moduledoc "A checker tried to start a command rather than approve one that is waiting. HTTP 403."
    defexception [:permission]

    @impl true
    def message(%{permission: permission}),
      do: "Checker can only approve a pending submission; there is none for #{permission}"
  end

  defmodule DuplicatePendingSubmission do
    @moduledoc "An identical command is already waiting for approval. HTTP 403."
    defexception [:action_name, :entity_name]

    @impl true
    def message(%{action_name: action, entity_name: entity}),
      do: "Maker-checker: #{action} #{entity} is already submitted and waiting for approval"
  end

  defmodule RollbackNotApproved do
    @moduledoc """
    Not an error to the user: the command was valid, was rolled back, and now waits for a checker.
    The API answers HTTP 202 with the command and resource ids.
    """
    defexception [:command_id, :resource_id]

    @impl true
    def message(%{command_id: id}), do: "Command #{id} is awaiting approval"
  end

  defmodule CommandNotFound do
    @moduledoc "No stored command with that id. HTTP 404."
    defexception [:command_id]

    @impl true
    def message(%{command_id: id}), do: "Command with identifier #{id} does not exist"
  end

  defmodule CommandNotAwaitingApproval do
    @moduledoc "The command is not waiting for approval. HTTP 404."
    defexception [:command_id]

    @impl true
    def message(%{command_id: id}), do: "Command with identifier #{id} is not awaiting approval"
  end

  defmodule UnsupportedCommand do
    @moduledoc "No handler for the command, or the command may not be run this way. HTTP 400."
    defexception [:command, :detail]

    @impl true
    def message(%{command: command, detail: nil}), do: "Unsupported command: #{command}"

    def message(%{command: command, detail: detail}),
      do: "Unsupported command: #{command} (#{detail})"
  end

  defmodule IdempotentUnderProcessing do
    @moduledoc "The same request is still being processed. HTTP 409."
    defexception [:action_name, :entity_name, :idempotency_key]

    @impl true
    def message(%{action_name: a, entity_name: e, idempotency_key: k}),
      do: "A request with idempotency key #{k} (#{a} #{e}) is still being processed"
  end

  defmodule IdempotentSucceeded do
    @moduledoc """
    The same request already succeeded. Not a failure: `command_source` holds the stored result, which
    the API returns with the header `x-served-from-cache: true`.
    """
    defexception [:action_name, :entity_name, :idempotency_key, :command_source]

    @impl true
    def message(%{action_name: a, entity_name: e, idempotency_key: k}),
      do: "A request with idempotency key #{k} (#{a} #{e}) has already succeeded"
  end

  defmodule IdempotentFailed do
    @moduledoc "The same request already failed; the stored error is in `command_source`. Returned unless the caller is retrying."
    defexception [:action_name, :entity_name, :idempotency_key, :command_source]

    @impl true
    def message(%{action_name: a, entity_name: e, idempotency_key: k}),
      do: "A request with idempotency key #{k} (#{a} #{e}) has already failed"
  end

  @doc "The HTTP status Fineract answers with for an error."
  @spec http_status(Exception.t()) :: pos_integer
  def http_status(%NoAuthorization{}), do: 403
  def http_status(%CheckerOnlyInitiation{}), do: 403
  def http_status(%DuplicatePendingSubmission{}), do: 403
  def http_status(%PermissionNotFound{}), do: 404
  def http_status(%CommandNotFound{}), do: 404
  def http_status(%CommandNotAwaitingApproval{}), do: 404
  def http_status(%UnsupportedCommand{}), do: 400
  def http_status(%RollbackNotApproved{}), do: 202
  def http_status(%IdempotentUnderProcessing{}), do: 409
  def http_status(%IdempotentSucceeded{}), do: 200

  def http_status(%IdempotentFailed{command_source: %{result_status_code: code}})
      when is_integer(code),
      do: code

  def http_status(other) do
    case ECBPlatform.Errors.to_api(other) do
      {status, _body} -> status
      nil -> 500
    end
  end

  @doc """
  The body Fineract sends for an error and stores with a failed command: `developerMessage`,
  `httpStatusCode`, `defaultUserMessage`, `userMessageGlobalisationCode` and an `errors` list.
  """
  @spec to_api_map(Exception.t()) :: map
  def to_api_map(exception) do
    case ECBPlatform.Errors.to_api(exception) do
      {_status, body} -> body
      nil -> generic_api_map(exception)
    end
  end

  defp generic_api_map(exception) do
    message = Exception.message(exception)

    %{
      "developerMessage" => message,
      "httpStatusCode" => Integer.to_string(http_status(exception)),
      "defaultUserMessage" => message,
      "userMessageGlobalisationCode" => error_code(exception),
      "errors" => []
    }
  end

  @doc "A stable short code for the error, stored with a failed command."
  @spec error_code(Exception.t()) :: String.t()
  def error_code(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> then(&"error.msg.platform.#{&1}")
  end
end
