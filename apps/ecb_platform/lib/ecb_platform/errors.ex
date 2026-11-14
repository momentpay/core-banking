defmodule ECBPlatform.Errors do
  @moduledoc """
  Errors raised or returned by the platform read and write models, with the response Fineract sends
  for each.

  Every error here can say what an API answers (`to_api/1`): an HTTP status and the body. The API layer
  just serialises it, and the command pipeline stores the same body with a failed command.

  Fineract's error body has `developerMessage`, `httpStatusCode`, `defaultUserMessage`,
  `userMessageGlobalisationCode` and a list of `errors`; each entry of the list has the same message
  fields plus `parameterName` and `args`.
  """

  @validation_developer_message "The request was invalid. This typically will happen due to validation errors which are provided."
  @data_integrity_developer_message "The request caused a data integrity issue to be fired by the database."

  # --- the building blocks --------------------------------------------------------------------

  @typedoc "One entry of the `errors` list."
  @type parameter_error :: %{
          required(:code) => String.t(),
          required(:developer_message) => String.t(),
          required(:default_message) => String.t(),
          optional(:parameter) => String.t() | nil,
          optional(:args) => [term]
        }

  @doc "A parameter error whose developer and default messages are the same text."
  @spec parameter_error(String.t(), String.t(), String.t() | nil, [term]) :: parameter_error
  def parameter_error(code, message, parameter, args \\ []) do
    %{
      code: code,
      developer_message: message,
      default_message: message,
      parameter: parameter,
      args: args
    }
  end

  @doc false
  def error_json(error) do
    base = %{
      "developerMessage" => error.developer_message,
      "defaultUserMessage" => error.default_message,
      "userMessageGlobalisationCode" => error.code,
      "args" => Enum.map(Map.get(error, :args, []), &arg_json/1)
    }

    base =
      case Map.get(error, :parameter) do
        nil -> base
        parameter -> Map.put(base, "parameterName", parameter)
      end

    # some errors also show the value that was refused
    case Map.get(error, :value) do
      nil -> base
      value -> Map.put(base, "value", value)
    end
  end

  defp arg_json(nil), do: %{}
  defp arg_json(value), do: %{"value" => value}

  # --- the errors -----------------------------------------------------------------------------

  defmodule ResourceNotFound do
    @moduledoc """
    A platform resource (a role, a user, a configuration property) that does not exist. HTTP 404.
    `code` is the message code Fineract uses, `args` the values it shows.
    """
    defexception [:code, :message, :args]

    @doc "Builds the error."
    def new(code, message, args), do: %__MODULE__{code: code, message: message, args: args}
  end

  defmodule PlatformApiDataValidation do
    @moduledoc "One or more request values failed validation. HTTP 400 with the list of problems."
    defexception errors: []

    @impl true
    def message(%{errors: errors}),
      do: "Validation errors exist: " <> Enum.map_join(errors, "; ", & &1.default_message)
  end

  defmodule UnsupportedParameter do
    @moduledoc "The request has parameters this operation does not know. HTTP 400."
    defexception parameters: []

    @impl true
    def message(%{parameters: parameters}),
      do: "Unsupported parameters: " <> Enum.join(parameters, ", ")
  end

  defmodule InvalidJson do
    @moduledoc "The body is missing or is not JSON of the expected shape. HTTP 400."
    defexception [:detail]

    @impl true
    def message(%{detail: nil}),
      do: "The JSON provided in the body of the request is invalid or missing."

    def message(%{detail: detail}),
      do: "The JSON syntax provided in the body of the request is invalid: " <> detail
  end

  defmodule InvalidJsonData do
    @moduledoc """
    A value of the wrong type in a typed request, such as text where a true or false belongs. HTTP 400,
    with Fineract's single message.
    """
    defexception message:
                   "The referenced JSON data is invalid, validate date format as yyyy-MM-dd or other cases like String instead of Number"
  end

  defmodule DataIntegrity do
    @moduledoc """
    A rule the data store enforces was broken, such as a duplicate name. HTTP 403 with the message code
    of the specific rule, as `PlatformDataIntegrityException` in Fineract.
    """
    defexception [:code, :message, :parameter, args: []]
  end

  defmodule DomainRuleViolation do
    @moduledoc "The request was understood but breaks a business rule. HTTP 403."
    defexception [:code, :message, args: []]
  end

  # --- what an API answers --------------------------------------------------------------------

  @doc """
  The HTTP status and JSON body Fineract answers with for one of these errors, or `nil` for any other
  exception.
  """
  @spec to_api(Exception.t()) :: {pos_integer, map} | nil
  def to_api(%ResourceNotFound{} = e) do
    generic = "The requested resource is not available."

    {404,
     envelope(404, "error.msg.resource.not.found", generic, generic, [
       parameter_error(e.code, e.message, "id", e.args)
     ])}
  end

  def to_api(%PlatformApiDataValidation{errors: errors}) do
    {400,
     envelope(
       400,
       "validation.msg.validation.errors.exist",
       @validation_developer_message,
       "Validation errors exist.",
       errors
     )}
  end

  def to_api(%UnsupportedParameter{parameters: parameters}) do
    errors =
      for name <- parameters do
        %{
          code: "error.msg.parameter.unsupported",
          developer_message: "The parameter #{name} is not supported.",
          default_message: name,
          parameter: name,
          args: []
        }
      end

    {400,
     envelope(
       400,
       "validation.msg.validation.errors.exist",
       @validation_developer_message,
       "Validation errors exist.",
       errors
     )}
  end

  def to_api(%InvalidJson{} = e) do
    message = Exception.message(e)

    {400,
     error_json(%{
       developer_message: message,
       default_message: message,
       code: "error.msg.invalid.request.body",
       parameter: "id",
       args: []
     })}
  end

  def to_api(%InvalidJsonData{} = e) do
    {400,
     error_json(%{
       developer_message: e.message,
       default_message: e.message,
       code: "error.msg.invalid.json.data",
       parameter: "id",
       args: []
     })}
  end

  def to_api(%DataIntegrity{} = e) do
    entry = %{
      code: e.code,
      developer_message: @data_integrity_developer_message,
      default_message: e.message,
      parameter: e.parameter,
      args: e.args
    }

    {403, envelope(403, e.code, @data_integrity_developer_message, e.message, [entry])}
  end

  def to_api(%DomainRuleViolation{} = e) do
    {403,
     envelope(
       403,
       "validation.msg.domain.rule.violation",
       "Request was understood but caused a domain rule violation.",
       "Errors contain reason for domain rule violation.",
       [parameter_error(e.code, e.message, "id", e.args)]
     )}
  end

  def to_api(_other), do: nil

  defp envelope(status, code, developer_message, default_message, errors) do
    %{
      "developerMessage" => developer_message,
      "httpStatusCode" => Integer.to_string(status),
      "defaultUserMessage" => default_message,
      "userMessageGlobalisationCode" => code,
      "errors" => Enum.map(errors, &error_json/1)
    }
  end
end
