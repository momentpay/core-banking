defmodule ECBOrg.Handlers do
  @moduledoc """
  The command handlers of the organisation app, one module per command. Each reads the request body
  from the command and calls the module that does the work; the pipeline around it checks permissions,
  stores the command and runs the handler in a transaction.
  """

  defmodule CreateFund do
    @moduledoc "`CREATE` on `FUND`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.Funds.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateFund do
    @moduledoc "`UPDATE` on `FUND`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.Funds.Write.update!(command.entity_id, ECBPlatform.Params.parse!(command.json))}
  end

  defmodule CreatePaymentType do
    @moduledoc "`CREATE` on `PAYMENTTYPE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.PaymentTypes.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdatePaymentType do
    @moduledoc "`UPDATE` on `PAYMENTTYPE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.PaymentTypes.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule DeletePaymentType do
    @moduledoc "`DELETE` on `PAYMENTTYPE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBOrg.PaymentTypes.Write.delete!(command.entity_id)}
  end

  defmodule CreateStaff do
    @moduledoc "`CREATE` on `STAFF`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.Staff.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateStaff do
    @moduledoc "`UPDATE` on `STAFF`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.Staff.Write.update!(command.entity_id, ECBPlatform.Params.parse!(command.json))}
  end
end
