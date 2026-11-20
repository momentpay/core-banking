defmodule ECBDeposits.Savings.PayDueChargesJob do
  @moduledoc """
  The job "Pay Due Savings Charges" (`SA_PDCH`), after Fineract's `PayDueSavingsChargesTasklet`: for every charge of an
  active account that has a due date on or before today and is neither paid nor waived nor inactive, pays what is
  outstanding on the business date for as long as it fell due before it. A charge it cannot pay is skipped and the
  run recorded failed.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.ChargeCommands
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @active 300

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    today = BusinessDate.current()

    failures =
      from(c in "m_savings_account_charge",
        join: a in "m_savings_account",
        on: a.id == c.savings_account_id,
        where:
          not is_nil(c.charge_due_date) and c.charge_due_date <= ^today and not c.waived and
            not c.is_paid_derived and c.is_active and a.status_enum == ^@active,
        order_by: [c.charge_due_date, c.id],
        select: {c.id, c.savings_account_id}
      )
      |> TenantRepo.all()
      |> Enum.flat_map(fn {charge_id, account_id} -> pay(user, charge_id, account_id) end)

    if failures != [] do
      raise "Pay Due Savings Charges failed for " <>
              Enum.map_join(failures, "; ", fn {id, message} -> "charge #{id}: #{message}" end)
    end

    :ok
  end

  defp pay(user, charge_id, account_id) do
    {:ok, _} =
      TenantRepo.transaction(fn -> ChargeCommands.pay_due!(user, charge_id, account_id) end)

    []
  rescue
    error -> [{charge_id, Exception.message(error)}]
  end
end

defmodule ECBDeposits.Savings.ApplyAnnualFeeJob do
  @moduledoc """
  The job "Apply Annual Fee For Savings" (`SA_AANF`), after Fineract's `ApplyAnnualFeeForSavingsTasklet`: pays the
  annual fee of every active account whose due date is on or before today, on each day it fell due. A failing
  account is left alone and the others go on.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.ChargeCommands
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @active 300
  @annual 6

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    today = BusinessDate.current()

    from(c in "m_savings_account_charge",
      join: a in "m_savings_account",
      on: a.id == c.savings_account_id,
      where:
        not is_nil(c.charge_due_date) and c.charge_time_enum == ^@annual and
          c.charge_due_date <= ^today and
          a.status_enum == ^@active,
      order_by: c.id,
      select: {c.id, c.savings_account_id}
    )
    |> TenantRepo.all()
    |> Enum.each(fn {charge_id, account_id} -> apply_fee(user, charge_id, account_id) end)

    :ok
  end

  # the account that cannot pay is skipped: Fineract logs it and goes on
  defp apply_fee(user, charge_id, account_id) do
    TenantRepo.transaction(fn ->
      ChargeCommands.apply_annual_fee!(user, charge_id, account_id)
    end)
  rescue
    _error -> :skipped
  end
end
