defmodule ECBCatalog.Handlers do
  @moduledoc """
  The command handlers of the catalog, one module per command. Each reads the request body from the command
  and calls the module that does the work; the pipeline around it checks permissions, stores the command and
  runs the handler in a transaction.
  """

  defmodule CreateTaxComponent do
    @moduledoc "`CREATE` on `TAXCOMPONENT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBCatalog.Taxes.Write.create_component!(
           ECBPlatform.Params.parse_typed!(command.json),
           user
         )}
  end

  defmodule UpdateTaxComponent do
    @moduledoc "`UPDATE` on `TAXCOMPONENT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBCatalog.Taxes.Write.update_component!(
           command.entity_id,
           ECBPlatform.Params.parse_typed!(command.json),
           user
         )}
  end

  defmodule CreateTaxGroup do
    @moduledoc "`CREATE` on `TAXGROUP`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBCatalog.Taxes.Write.create_group!(ECBPlatform.Params.parse_typed!(command.json), user)}
  end

  defmodule UpdateTaxGroup do
    @moduledoc "`UPDATE` on `TAXGROUP`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBCatalog.Taxes.Write.update_group!(
           command.entity_id,
           ECBPlatform.Params.parse_typed!(command.json),
           user
         )}
  end

  defmodule CreateCharge do
    @moduledoc "`CREATE` on `CHARGE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBCatalog.Charges.Write.create!(ECBPlatform.Params.parse_typed!(command.json))}
  end

  defmodule UpdateCharge do
    @moduledoc "`UPDATE` on `CHARGE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBCatalog.Charges.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse_typed!(command.json)
         )}
  end

  defmodule DeleteCharge do
    @moduledoc "`DELETE` on `CHARGE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBCatalog.Charges.Write.delete!(command.entity_id)}
  end

  defmodule CreateRate do
    @moduledoc "`CREATE` on `RATE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do: {:ok, ECBCatalog.Rates.create!(ECBPlatform.Params.parse_typed!(command.json), user)}
  end

  defmodule UpdateRate do
    @moduledoc "`UPDATE` on `RATE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBCatalog.Rates.update!(
           command.entity_id,
           ECBPlatform.Params.parse_typed!(command.json),
           user
         )}
  end

  defmodule CreateFloatingRate do
    @moduledoc "`CREATE` on `FLOATINGRATE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user) do
      # no body at all is an unhandled failure in Fineract, answered by a plain 500
      if command.json in [nil, ""], do: raise(ECBPlatform.Errors.ServerError)

      {:ok, ECBCatalog.FloatingRates.create!(ECBPlatform.Params.parse_typed!(command.json), user)}
    end
  end

  defmodule UpdateFloatingRate do
    @moduledoc "`UPDATE` on `FLOATINGRATE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBCatalog.FloatingRates.update!(
           command.entity_id,
           ECBPlatform.Params.parse_typed!(command.json),
           user
         )}
  end
end
