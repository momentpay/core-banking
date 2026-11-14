defmodule ECBPlatform.Commands.Handlers do
  @moduledoc """
  The registry that maps a command (entity and action) to the module that carries it out.

  Each domain app registers its handlers when it starts, so the platform never needs to know about
  clients, loans or deposits:

      def start(_type, _args) do
        ECBPlatform.Commands.Handlers.register("CLIENT", "CREATE", ECBParty.Clients.CreateHandler)
        ...
      end

  Registrations are kept in `:persistent_term`: reads are free, and writes (a few at boot) are rare.
  """

  alias ECBPlatform.Commands.Errors.UnsupportedCommand

  @key {__MODULE__, :table}

  @doc "Registers `module` as the handler for `action` on `entity`. Replaces an earlier registration."
  @spec register(String.t(), String.t(), module) :: :ok
  def register(entity, action, module)
      when is_binary(entity) and is_binary(action) and is_atom(module) do
    :persistent_term.put(@key, Map.put(table(), {entity, action}, module))
  end

  @doc "Removes a registration (used by tests)."
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(entity, action),
    do: :persistent_term.put(@key, Map.delete(table(), {entity, action}))

  @doc "The handler for a command, or `{:error, UnsupportedCommand}`."
  @spec fetch(String.t(), String.t()) :: {:ok, module} | {:error, Exception.t()}
  def fetch(entity, action) do
    case Map.fetch(table(), {entity, action}) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         %UnsupportedCommand{command: "#{action}_#{entity}", detail: "no handler registered"}}
    end
  end

  @doc "All registrations, as `{{entity, action}, module}` pairs."
  @spec all() :: [{{String.t(), String.t()}, module}]
  def all, do: Enum.sort(table())

  defp table, do: :persistent_term.get(@key, %{})
end
