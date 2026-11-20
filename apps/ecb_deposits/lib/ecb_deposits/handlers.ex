defmodule ECBDeposits.Handlers do
  @moduledoc "The commands the deposits app handles, one handler per entity."

  defmodule SavingsProduct do
    @moduledoc "Every action on `SAVINGSPRODUCT`: create, update and delete."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.SavingsProducts.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, Write.create!(Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, Write.update!(command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, _user),
      do: {:ok, Write.delete!(command.entity_id)}
  end

  defmodule FixedDepositProduct do
    @moduledoc "Every action on `FIXEDDEPOSITPRODUCT`: create, update and delete."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.DepositProducts.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, Write.create!(:fixed, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, Write.update!(:fixed, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, _user),
      do: {:ok, Write.delete!(:fixed, command.entity_id)}
  end

  defmodule RecurringDepositProduct do
    @moduledoc "Every action on `RECURRINGDEPOSITPRODUCT`: create, update and delete."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.DepositProducts.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, Write.create!(:recurring, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, Write.update!(:recurring, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, _user),
      do: {:ok, Write.delete!(:recurring, command.entity_id)}
  end

  defmodule FixedDepositAccount do
    @moduledoc "Every action on `FIXEDDEPOSITACCOUNT`: applying, changing, the steps to activation."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.DepositAccounts.{Activation, Submit}
    alias ECBDeposits.Savings.Transitions
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Submit.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user),
      do: {:ok, Submit.modify!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Submit.delete!(user, command.entity_id)}

    def process(%{action_name: "ACTIVATE"} = command, user),
      do: {:ok, Activation.activate!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: name} = command, user)
        when name in ~w(APPROVE APPROVALUNDO REJECT WITHDRAW) do
      id = Submit.writable!(command.entity_id).id
      params = Params.parse!(command.json)

      {:ok,
       case name do
         "APPROVE" -> Transitions.approve!(user, id, params)
         "APPROVALUNDO" -> Transitions.undo_approval!(user, id, params)
         "REJECT" -> Transitions.reject!(user, id, params)
         "WITHDRAW" -> Transitions.withdraw!(user, id, params)
       end}
    end
  end

  defmodule SavingsAccount do
    @moduledoc """
    Every action on `SAVINGSACCOUNT` so far: apply, change and delete an application, approve it, take the approval
    back, reject it, withdraw it, activate the account and close it, and the deposits, withdrawals and corrections of
    its transactions.
    """
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.Savings.{
      Blocks,
      Holds,
      InterestCommands,
      Officers,
      Postings,
      Submit,
      Transitions
    }

    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Submit.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user),
      do: {:ok, Submit.modify!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Submit.delete!(user, command.entity_id)}

    def process(%{action_name: "APPROVE"} = command, user),
      do: {:ok, Transitions.approve!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "APPROVALUNDO"} = command, user),
      do: {:ok, Transitions.undo_approval!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "REJECT"} = command, user),
      do: {:ok, Transitions.reject!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "WITHDRAW"} = command, user),
      do: {:ok, Transitions.withdraw!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "ACTIVATE"} = command, user),
      do: {:ok, Transitions.activate!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "CLOSE"} = command, user),
      do: {:ok, Transitions.close!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DEPOSIT"} = command, user),
      do: {:ok, Postings.deposit!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "WITHDRAWAL"} = command, user),
      do: {:ok, Postings.withdraw!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "FORCE_WITHDRAWAL"} = command, user),
      do: {:ok, Postings.withdraw!(user, command.entity_id, Params.parse!(command.json), true)}

    def process(%{action_name: "UNDOTRANSACTION"} = command, user),
      do: {:ok, Postings.undo!(user, command.entity_id, command.subentity_id)}

    def process(%{action_name: "REVERSETRANSACTION"} = command, user),
      do: {:ok, Postings.reverse!(user, command.entity_id, command.subentity_id)}

    def process(%{action_name: "CALCULATEINTEREST"} = command, user),
      do: {:ok, InterestCommands.calculate!(user, command.entity_id)}

    def process(%{action_name: "POSTINTEREST"} = command, user),
      do: {:ok, InterestCommands.post!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "ASSIGNSAVINGSOFFICER"} = command, user),
      do: {:ok, Officers.assign!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UNASSIGNSAVINGSOFFICER"} = command, user),
      do: {:ok, Officers.unassign!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "BLOCK"} = command, user),
      do: {:ok, Blocks.block!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UNBLOCK"} = command, user),
      do: {:ok, Blocks.unblock!(user, command.entity_id)}

    def process(%{action_name: "BLOCKCREDITS"} = command, user),
      do: {:ok, Blocks.block_credits!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UNBLOCKCREDITS"} = command, user),
      do: {:ok, Blocks.unblock_credits!(user, command.entity_id)}

    def process(%{action_name: "BLOCKDEBITS"} = command, user),
      do: {:ok, Blocks.block_debits!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UNBLOCKDEBITS"} = command, user),
      do: {:ok, Blocks.unblock_debits!(user, command.entity_id)}

    def process(%{action_name: "HOLDAMOUNT"} = command, user),
      do: {:ok, Holds.hold!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "RELEASEAMOUNT"} = command, user),
      do:
        {:ok,
         Holds.release!(
           user,
           command.entity_id,
           command.subentity_id,
           Params.parse!(command.json)
         )}

    def process(%{action_name: "ADJUSTTRANSACTION"} = command, user),
      do:
        {:ok,
         Postings.adjust!(
           user,
           command.entity_id,
           command.subentity_id,
           Params.parse!(command.json)
         )}
  end

  defmodule SavingsAccountCharge do
    @moduledoc """
    Every action on `SAVINGSACCOUNTCHARGE`: add a charge to a savings account, change, delete, pay, waive and
    inactivate one. The account is the command's entity, the charge its sub-entity.
    """
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.Savings.ChargeCommands
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, ChargeCommands.add!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user),
      do:
        {:ok,
         ChargeCommands.update!(
           user,
           command.entity_id,
           command.subentity_id,
           Params.parse!(command.json)
         )}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, ChargeCommands.delete!(user, command.entity_id, command.subentity_id)}

    def process(%{action_name: "WAIVE"} = command, user),
      do: {:ok, ChargeCommands.waive!(user, command.entity_id, command.subentity_id)}

    def process(%{action_name: "PAY"} = command, user),
      do:
        {:ok,
         ChargeCommands.pay!(
           user,
           command.entity_id,
           command.subentity_id,
           Params.parse!(command.json)
         )}

    def process(%{action_name: "INACTIVATE"} = command, user),
      do: {:ok, ChargeCommands.inactivate!(user, command.entity_id, command.subentity_id)}
  end
end
