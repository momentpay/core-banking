defmodule ECBLoans.Handlers do
  @moduledoc "The commands the loans app handles, one handler per entity."

  defmodule LoanProduct do
    @moduledoc "Every action on `LOANPRODUCT`: create and update (a loan product cannot be deleted)."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.LoanProducts.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, Write.create!(Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, Write.update!(command.entity_id, Params.parse!(command.json))}
  end

  defmodule Loan do
    @moduledoc """
    Every action on `LOAN` so far: submit an application, approve it, take the approval back, reject it,
    withdraw it, and delete it.
    """
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.Loans.{Disburse, Submit, Transitions}
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Submit.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "APPROVE"} = command, user),
      do: {:ok, Transitions.approve!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "APPROVALUNDO"} = command, user),
      do: {:ok, Transitions.undo_approval!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "REJECT"} = command, user),
      do: {:ok, Transitions.reject!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "WITHDRAW"} = command, user),
      do: {:ok, Transitions.withdraw!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DISBURSE"} = command, user),
      do: {:ok, Disburse.disburse!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Transitions.delete!(user, command.entity_id)}
  end
end
