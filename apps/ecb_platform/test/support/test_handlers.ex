defmodule ECBPlatform.TestHandlers do
  @moduledoc """
  Command handlers for tests. Each writes a row (a role named after the request) before it decides
  what to return, so a test can tell whether the handler's work was kept or rolled back.
  """

  alias ECBPlatform.Commands.{Command, Result}
  alias ECBPlatform.TenantRepo

  @doc "Names of the rows handlers have written and not had rolled back."
  def written,
    do:
      TenantRepo.query!("SELECT name FROM m_role WHERE name LIKE 'test-widget-%' ORDER BY name").rows
      |> List.flatten()

  defp write(command) do
    name = "test-widget-" <> Map.get(Command.data(command), "name", "unnamed")

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_role",
        [%{name: name, description: "written by a test handler", is_disabled: false}],
        returning: [:id]
      )

    id
  end

  defmodule Succeed do
    @moduledoc false
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user) do
      id = ECBPlatform.TestHandlers.write_public(command)

      {:ok,
       Result.new(
         resource_id: id,
         office_id: 1,
         client_id: 7,
         changes: %{"name" => "x"},
         command_id: command.command_source_id
       )}
    end
  end

  defmodule Fail do
    @moduledoc false
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user) do
      ECBPlatform.TestHandlers.write_public(command)

      {:error,
       %ECBPlatform.Commands.Errors.UnsupportedCommand{command: "FAIL", detail: "on purpose"}}
    end
  end

  defmodule Raise do
    @moduledoc false
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user) do
      ECBPlatform.TestHandlers.write_public(command)
      raise "handler blew up"
    end
  end

  defmodule DryRun do
    @moduledoc false
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user) do
      id = ECBPlatform.TestHandlers.write_public(command)
      {:ok, Result.new(resource_id: id, rollback_transaction: true)}
    end
  end

  defmodule Garbage do
    @moduledoc false
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(_command, _user), do: :not_a_result
  end

  @doc false
  def write_public(command), do: write(command)

  defmodule Hook do
    @moduledoc "Reports hook calls to the process registered as :hook_test."
    def after_success(command, result), do: notify({:success, command.action_name, result})
    def after_error(command, error), do: notify({:error, command.action_name, error})

    defp notify(message) do
      if pid = Process.whereis(:hook_test), do: send(pid, message)
      :ok
    end
  end

  defmodule BrokenHook do
    @moduledoc false
    def after_success(_command, _result), do: raise("hook failed")
    def after_error(_command, _error), do: raise("hook failed")
  end
end
