defmodule ECBDeposits.DepositAccounts.MaturityJob do
  @moduledoc """
  The job "Update Deposit Accounts Maturity details" (`SA_MATD`), after Fineract's
  `UpdateDepositsAccountMaturityDetailsTasklet`. A fixed deposit that is active and has come to the end of its term
  matures: the interest of the whole term is posted and the account is matured, ready to be closed. Each account is
  dealt with on its own and a failure is recorded after the others are done.
  """
  import Ecto.Query

  alias ECBDeposits.DepositAccounts.{FixedInterest, Submit}
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @fixed 200
  @active 300
  @matured 800

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    today = BusinessDate.current()

    failures =
      today
      |> pending()
      |> Enum.flat_map(&attempt(user, &1))

    if failures != [] do
      raise "Update Deposit Accounts Maturity details failed for " <>
              Enum.map_join(failures, "; ", fn {id, message} -> "account #{id}: #{message}" end)
    end

    :ok
  end

  # the active deposits whose term has ended
  defp pending(today) do
    from(a in "m_savings_account",
      join: t in "m_deposit_account_term_and_preclosure",
      on: t.savings_account_id == a.id,
      where:
        a.deposit_type_enum == ^@fixed and a.status_enum == ^@active and
          not is_nil(t.maturity_date) and t.maturity_date <= ^today,
      order_by: a.id,
      select: a.id
    )
    |> TenantRepo.all()
  end

  defp attempt(user, id) do
    {:ok, _} = TenantRepo.transaction(fn -> mature!(user, id) end)
    []
  rescue
    error -> [{id, Exception.message(error)}]
  end

  defp mature!(user, id) do
    account = Submit.writable!(id)

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [status_enum: @matured]
    )

    FixedInterest.post_maturity_interest!(user, %{account | status_enum: @matured})
    :ok
  end
end
