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

    alias ECBLoans.Loans.{Corrections, Disburse, Modify, Repay, Submit, Transitions}
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Submit.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user),
      do: {:ok, Modify.modify!(user, command.entity_id, Params.parse!(command.json))}

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

    def process(%{action_name: "REPAYMENT"} = command, user),
      do: {:ok, Repay.repay!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "ADJUST"} = command, user),
      do:
        {:ok,
         Corrections.adjust!(
           user,
           command.entity_id,
           command.subentity_id,
           Params.parse!(command.json)
         )}

    def process(%{action_name: "WAIVEINTERESTPORTION"} = command, user),
      do: {:ok, Corrections.waive_interest!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "WRITEOFF"} = command, user),
      do: {:ok, Corrections.write_off!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DISBURSALUNDO"} = command, user),
      do: {:ok, Corrections.undo_disbursal!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Transitions.delete!(user, command.entity_id)}
  end

  defmodule LoanCharge do
    @moduledoc """
    Every action on `LOANCHARGE`: add a charge to a loan, waive it, change or delete it, and the refusal of paying
    it by itself.
    """
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.Loans.ChargeActions
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, ChargeActions.add!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "WAIVE"} = command, user),
      do: {:ok, charge_action(&ChargeActions.waive!/4, command, user)}

    def process(%{action_name: "PAY"} = command, user),
      do: {:ok, charge_action(&ChargeActions.pay!/4, command, user)}

    def process(%{action_name: "ADJUSTMENT"} = command, user),
      do: {:ok, charge_action(&ChargeActions.adjust!/4, command, user)}

    def process(%{action_name: "UPDATE"} = command, user),
      do: {:ok, charge_action(&ChargeActions.update!/4, command, user)}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, ChargeActions.delete!(user, command.entity_id, command.subentity_id)}

    defp charge_action(fun, command, user),
      do: fun.(user, command.entity_id, command.subentity_id, Params.parse!(command.json))
  end
end
