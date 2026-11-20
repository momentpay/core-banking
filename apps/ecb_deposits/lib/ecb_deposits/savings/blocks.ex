defmodule ECBDeposits.Savings.Blocks do
  @moduledoc """
  Blocking an account, or only its credits or only its debits, and lifting the block, after Fineract's
  `SavingsAccount.block`, `blockCredits`, `blockDebits` and their opposites, and the write service's commands. The
  state is the sub status of the account (400 blocked, 500 credits blocked, 600 debits blocked); the reason given is
  kept with the account until a block is lifted. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings
  alias ECBDeposits.Savings.Transitions
  alias ECBDeposits.SavingsEnums
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DataIntegrity, DomainRuleViolation}
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @active 300
  @none 0
  @block 400
  @block_credit 500
  @block_debit 600

  # --- the commands -------------------------------------------------------------------------------

  @doc "Blocks the account altogether."
  @spec block!(struct, integer, Params.t()) :: Result.t()
  def block!(user, id, %Params{} = p) do
    account = Transitions.account!(id)
    check_active!(account, "block", "status")
    reason = reason!(p)
    set!(user, id, @block, reason)
    result(account, @block)
  end

  @doc "Lifts a block of the whole account."
  @spec unblock!(struct, integer) :: Result.t()
  def unblock!(user, id) do
    account = Transitions.account!(id)
    v = Validation.new("savingsaccount.unblock")
    v = if active?(account), do: v, else: fail(v, "status", "not.in.active.state")

    v =
      if account.sub_status_enum == @block,
        do: v,
        else: fail(v, "subStatus", "not.in.blocked.state")

    Validation.raise_if_errors!(v)
    set!(user, id, @none, nil)
    result(account, @none)
  end

  @doc "Blocks the credits to the account (with the debits blocked it is blocked altogether)."
  @spec block_credits!(struct, integer, Params.t()) :: Result.t()
  def block_credits!(user, id, %Params{} = p), do: partial!(user, id, p, :credits)

  @doc "Blocks the debits from the account (with the credits blocked it is blocked altogether)."
  @spec block_debits!(struct, integer, Params.t()) :: Result.t()
  def block_debits!(user, id, %Params{} = p), do: partial!(user, id, p, :debits)

  @doc "Lifts the block of the credits."
  @spec unblock_credits!(struct, integer) :: Result.t()
  def unblock_credits!(user, id), do: lift!(user, id, :credits)

  @doc "Lifts the block of the debits."
  @spec unblock_debits!(struct, integer) :: Result.t()
  def unblock_debits!(user, id), do: lift!(user, id, :debits)

  defp partial!(user, id, p, kind) do
    account = Transitions.account!(id)
    reason = reason!(p)
    sub = account.sub_status_enum
    resource = if kind == :credits, do: "blockCredits", else: "blockDebits"

    v = Validation.new("savingsaccount." <> resource)
    v = if active?(account), do: v, else: fail(v, "status", "not.in.active.state")

    v =
      if sub == @block,
        do:
          v
          |> Validation.param("subStatus", "BLOCK")
          |> Validation.fail_without_parameter("currently.set"),
        else: v

    Validation.raise_if_errors!(v)

    {own, other} =
      if kind == :credits, do: {@block_credit, @block_debit}, else: {@block_debit, @block_credit}

    new = if sub == other, do: @block, else: own
    set!(user, id, new, reason)
    result(account, new)
  end

  defp lift!(user, id, kind) do
    account = Transitions.account!(id)
    sub = account.sub_status_enum

    {resource, own, other, code, param} =
      if kind == :credits,
        do: {"unblockCredits", @block_credit, @block_debit, "credits.are.not.blocked", "status"},
        else:
          {"unblockDebits", @block_debit, @block_credit, "debits.are.not.blocked", "subStatus"}

    v = Validation.new("savingsaccount." <> resource)

    # lifting the credits names no parameter for an account that is not active; the other three do
    v =
      if active?(account),
        do: v,
        else: fail(v, if(kind == :credits, do: nil, else: "status"), "not.in.active.state")

    v = if sub in [own, @block], do: v, else: fail(v, param, code)
    Validation.raise_if_errors!(v)

    new = if sub == @block, do: other, else: @none
    set!(user, id, new, nil)
    result(account, new)
  end

  # --- the state ------------------------------------------------------------------------------------

  defp active?(account), do: account.status_enum == @active

  defp check_active!(account, resource, parameter) do
    if not active?(account) do
      "savingsaccount."
      |> Kernel.<>(resource)
      |> Validation.new()
      |> fail(parameter, "not.in.active.state")
      |> Validation.raise_if_errors!()
    end
  end

  defp fail(v, parameter, code) do
    v |> Validation.param(parameter, nil) |> Validation.fail_without_parameter(code)
  end

  # a reason for blocking is mandatory
  defp reason!(p) do
    reason = Params.string(p, "reasonForBlock")

    if reason == nil or String.trim(reason) == "" do
      raise DataIntegrity,
        code: "Reason For Block is Mandatory",
        message: "error.msg.reason.for.block.mandatory"
    end

    reason
  end

  defp set!(user, id, sub_status, reason) do
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [
        sub_status_enum: sub_status,
        reason_for_block: reason,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )
  end

  defp result(account, sub_status) do
    Result.new(
      resource_id: account.id,
      savings_id: account.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      changes: %{"subStatus" => SavingsEnums.sub_status(sub_status)}
    )
  end

  # --- what a block forbids ----------------------------------------------------------------------------

  @doc """
  Refuses money coming into the account (`:credit`) or going out of it (`:debit`) when the account is blocked, as
  `SavingsAccount.validateForAccountBlock`, `validateForCreditBlock` and `validateForDebitBlock` do.
  """
  @spec check_transaction!(map, :credit | :debit) :: :ok
  def check_transaction!(account, direction) do
    id = account.id
    account = Savings.fetch!(id)

    cond do
      account.sub_status_enum == @block ->
        refuse!(
          "error.msg.saving.account.blocked.transaction.not.allowed",
          "Any transaction to #{id} is not allowed, since the account is blocked",
          id
        )

      direction == :credit and account.sub_status_enum == @block_credit ->
        refuse!(
          "error.msg.savings.account.credit.transaction.not.allowed",
          "Any Credit transactions to #{id} is not allowed, since the account is blocked for credits",
          id
        )

      direction == :debit and account.sub_status_enum == @block_debit ->
        refuse!(
          "error.msg.savings.account.debit.transaction.not.allowed",
          "Any debit transactions from #{id} is not allowed, since the account is blocked for debits",
          id
        )

      true ->
        :ok
    end
  end

  defp refuse!(code, message, id),
    do: raise(DomainRuleViolation, code: code, message: message, args: [id])

  @doc "True when the account is blocked in any way (what closing it may not be)."
  @spec blocked?(map) :: boolean
  def blocked?(account), do: account.sub_status_enum in [@block, @block_credit, @block_debit]
end
