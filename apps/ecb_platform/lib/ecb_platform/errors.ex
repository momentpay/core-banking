defmodule ECBPlatform.Errors do
  @moduledoc "Errors shared by the platform read models. The API layer turns them into Fineract's responses."

  defmodule ResourceNotFound do
    @moduledoc """
    A platform resource (a role, a user, a configuration property) that does not exist. HTTP 404.
    `code` is the message code Fineract uses, `args` the values it shows.
    """
    defexception [:code, :message, :args]

    @doc "Builds the error."
    def new(code, message, args), do: %__MODULE__{code: code, message: message, args: args}
  end
end
