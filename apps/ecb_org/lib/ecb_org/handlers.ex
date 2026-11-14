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

  defmodule CreateCode do
    @moduledoc "`CREATE` on `CODE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.Codes.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateCode do
    @moduledoc "`UPDATE` on `CODE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.Codes.Write.update!(command.entity_id, ECBPlatform.Params.parse!(command.json))}
  end

  defmodule DeleteCode do
    @moduledoc "`DELETE` on `CODE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBOrg.Codes.Write.delete!(command.entity_id)}
  end

  defmodule CreateCodeValue do
    @moduledoc "`CREATE` on `CODEVALUE`; the entity is the code the value is added to."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.Codes.Write.create_value!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule UpdateCodeValue do
    @moduledoc "`UPDATE` on `CODEVALUE`; the entity is the value."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.Codes.Write.update_value!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule DeleteCodeValue do
    @moduledoc "`DELETE` on `CODEVALUE`; the entity is the code, the sub-entity the value."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.Codes.Write.delete_value!(command.entity_id, command.subentity_id)}
  end

  defmodule UpdateWorkingDays do
    @moduledoc "`UPDATE` on `WORKINGDAYS`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.WorkingDays.Write.update!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule CreateHoliday do
    @moduledoc "`CREATE` on `HOLIDAY`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBOrg.Holidays.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateHoliday do
    @moduledoc "`UPDATE` on `HOLIDAY`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBOrg.Holidays.Write.update!(command.entity_id, ECBPlatform.Params.parse!(command.json))}
  end

  defmodule ActivateHoliday do
    @moduledoc "`ACTIVATE` on `HOLIDAY`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBOrg.Holidays.Write.activate!(command.entity_id)}
  end

  defmodule DeleteHoliday do
    @moduledoc "`DELETE` on `HOLIDAY`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBOrg.Holidays.Write.delete!(command.entity_id)}
  end
end
