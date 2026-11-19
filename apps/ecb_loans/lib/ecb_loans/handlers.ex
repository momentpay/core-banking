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

    alias ECBLoans.Loans.{
      ChargeOff,
      Closing,
      Corrections,
      Disburse,
      Foreclosure,
      Modify,
      Officers,
      Repay,
      Submit,
      Transitions,
      UndoLastDisbursal
    }

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

    def process(%{action_name: "MERCHANTISSUEDREFUND"} = command, user),
      do: {:ok, Repay.repay!(user, command.entity_id, Params.parse!(command.json), 21)}

    def process(%{action_name: "PAYOUTREFUND"} = command, user),
      do: {:ok, Repay.repay!(user, command.entity_id, Params.parse!(command.json), 22)}

    def process(%{action_name: "GOODWILLCREDIT"} = command, user),
      do: {:ok, Repay.repay!(user, command.entity_id, Params.parse!(command.json), 23)}

    def process(%{action_name: "UPDATELOANOFFICER"} = command, user),
      do: {:ok, Officers.reassign!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "REMOVELOANOFFICER"} = command, user),
      do: {:ok, Officers.unassign!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "RECOVERYPAYMENT"} = command, user),
      do: {:ok, Closing.recovery_payment!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UNDOWRITEOFF"} = command, user),
      do: {:ok, Closing.undo_write_off!(user, command.entity_id)}

    def process(%{action_name: "CLOSEASRESCHEDULED"} = command, user),
      do:
        {:ok, Closing.close_as_rescheduled!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "FORECLOSURE"} = command, user),
      do: {:ok, Foreclosure.foreclose!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "CHARGEOFF"} = command, user),
      do: {:ok, ChargeOff.charge_off!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UNDOCHARGEOFF"} = command, user),
      do: {:ok, ChargeOff.undo!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "CLOSE"} = command, user),
      do: {:ok, Closing.close!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "CREDITBALANCEREFUND"} = command, user),
      do:
        {:ok,
         Closing.credit_balance_refund!(user, command.entity_id, Params.parse!(command.json))}

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

    def process(%{action_name: "DISBURSALLASTUNDO"} = command, user),
      do: {:ok, UndoLastDisbursal.undo!(user, command.entity_id, Params.parse!(command.json))}

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

  defmodule RescheduleLoan do
    @moduledoc "Every action on `RESCHEDULELOAN`: ask for a loan to be rescheduled, approve or reject the request."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.Loans.Reschedule
    alias ECBLoans.RescheduleRequests
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, RescheduleRequests.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "APPROVE"} = command, user),
      do: {:ok, Reschedule.approve!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "REJECT"} = command, user),
      do: {:ok, RescheduleRequests.reject!(user, command.entity_id, Params.parse!(command.json))}
  end

  defmodule Collateral do
    @moduledoc "Every action on `COLLATERAL`: add a collateral to a loan, change its description, remove it."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.Collaterals
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Collaterals.create!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user) do
      {:ok,
       Collaterals.update!(
         user,
         command.entity_id,
         command.subentity_id,
         Params.parse!(command.json)
       )}
    end

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Collaterals.delete!(user, command.entity_id, command.subentity_id)}
  end

  defmodule Guarantor do
    @moduledoc "Every action on `GUARANTOR`: add a guarantor to a loan, change one, make one inactive."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.Guarantors
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Guarantors.create!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user) do
      {:ok,
       Guarantors.update!(
         user,
         command.entity_id,
         command.subentity_id,
         Params.parse!(command.json)
       )}
    end

    def process(%{action_name: "DELETE"} = command, user) do
      funding_id =
        case command.json && Jason.decode(command.json) do
          {:ok, %{"guarantorFundingId" => id}} -> id
          _ -> nil
        end

      {:ok, Guarantors.delete!(user, command.entity_id, command.subentity_id, funding_id)}
    end
  end
end
