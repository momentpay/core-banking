defmodule ECBDeposits.Savings.DormancyJob do
  @moduledoc """
  The job "Update Savings Dormant Accounts" (`SA_UDOR`), after Fineract's `UpdateSavingsDormantAccountsTasklet`. For
  the active accounts of products that track dormancy, it counts the days since the last deposit or withdrawal (the
  day of activation when there was none) up to the business date, and in this order
  makes the accounts that have gone as many days as the product says inactive (when they are not, paying their
  no activity fees on the balance they have), dormant (when inactive) and, last, escheats them: the account is closed
  by the system and its balance is taken out in a transaction of its own. Each account is dealt with on its own and
  a failure is recorded after the others are done.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.{Charges, Postings, Transitions}
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @active 300
  @closed 600
  @none 0
  @inactive 100
  @dormant 200
  @escheat 300

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    today = BusinessDate.current()

    failures =
      [
        {@none, :days_to_inactive, &inactive!/3},
        {@inactive, :days_to_dormancy, &dormant!/3},
        {@dormant, :days_to_escheat, &escheat!/3}
      ]
      |> Enum.flat_map(fn {from, field, action} ->
        from |> pending(field, today) |> Enum.flat_map(&attempt(&1, user, today, action))
      end)

    if failures != [] do
      raise "Update Savings Dormant Accounts failed for " <>
              Enum.map_join(failures, "; ", fn {id, message} -> "account #{id}: #{message}" end)
    end

    :ok
  end

  # the accounts in the sub status that have been without a deposit or withdrawal for as many days as the product says
  defp pending(sub_status, field, today) do
    from(a in "m_savings_account",
      join: p in "m_savings_product",
      on: p.id == a.product_id and p.is_dormancy_tracking_active == true,
      where: a.status_enum == ^@active and a.sub_status_enum == ^sub_status,
      order_by: a.id,
      select: %{id: a.id, activated: a.activatedon_date, days: field(p, ^field)}
    )
    |> TenantRepo.all()
    |> Enum.filter(fn a -> a.days != nil and idle_days(a, today) >= a.days end)
    |> Enum.map(& &1.id)
  end

  defp idle_days(account, today) do
    last =
      TenantRepo.one(
        from(t in "m_savings_account_transaction",
          where:
            t.savings_account_id == ^account.id and not t.is_reversed and not t.is_reversal and
              t.transaction_type_enum in [1, 2],
          select: max(t.transaction_date)
        )
      )

    Date.diff(today, last || account.activated)
  end

  defp attempt(id, user, today, action) do
    {:ok, _} = TenantRepo.transaction(fn -> action.(user, id, today) end)
    []
  rescue
    error -> [{id, Exception.message(error)}]
  end

  # inactive: the no activity fees of the account are paid, each on the balance the account has
  defp inactive!(user, id, today) do
    set!(user, id, sub_status_enum: @inactive)

    for charge <- Charges.list(id, "active"), Charges.no_activity?(charge) do
      account = Transitions.account!(id)

      fee =
        Charges.withdrawal_fee_amount(
          charge,
          account.account_balance_derived,
          account.currency_digits
        )

      Postings.pay_charge!(user, account, %{charge | outstanding: fee}, today, fee)
    end

    :ok
  end

  defp dormant!(user, id, _today), do: set!(user, id, sub_status_enum: @dormant)

  defp escheat!(user, id, today) do
    account = Transitions.account!(id)

    set!(user, id,
      status_enum: @closed,
      sub_status_enum: @escheat,
      closedon_date: today,
      closedon_userid: user.id
    )

    if Decimal.gt?(account.account_balance_derived, 0),
      do: Postings.escheat!(user, account, today)

    :ok
  end

  defp set!(user, id, fields) do
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: fields ++ [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]
    )
  end
end
