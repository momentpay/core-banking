defmodule ECBDeposits.Savings.PostInterestJob do
  @moduledoc """
  The job "Post Interest For Savings" (`SA_PINT`), after Fineract's `PostInterestForSavingTasklet`: posts the interest
  of every active savings account whose interest has not been posted up to yesterday (the accounts whose last posting
  is on or before yesterday, or that have none). An account it cannot do is skipped and the run recorded failed; an account it posts nothing for is left as it was.
  """
  import Ecto.Query

  alias ECBDeposits.Savings
  alias ECBDeposits.Savings.{Balance, Interest, Postings}
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @active 300

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    yesterday = Date.add(BusinessDate.current(), -1)

    failures =
      from(a in "m_savings_account",
        where:
          a.status_enum == ^@active and
            (is_nil(a.interest_posted_till_date) or a.interest_posted_till_date <= ^yesterday),
        order_by: a.id,
        select: a.id
      )
      |> TenantRepo.all()
      |> Enum.flat_map(&post(user, &1))

    if failures != [] do
      raise "Post Interest For Savings failed for " <>
              Enum.map_join(failures, "; ", fn {id, message} -> "account #{id}: #{message}" end)
    end

    :ok
  end

  # the same posting as the command, for an account that earns, or owes, interest
  defp post(user, id) do
    {:ok, _} = TenantRepo.transaction(fn -> post_one(user, Savings.fetch!(id)) end)
    []
  rescue
    error -> [{id, Exception.message(error)}]
  end

  defp post_one(user, account) do
    if Interest.calculating?(account) do
      plan = Interest.plan(account, Balance.live(account.id), precision: 10, mode: :post)

      # Fineract's job saves an account only when it posted something: what the account has earned since stays as
      # it was
      if plan.create != [] or plan.reverse != [], do: Postings.settle!(user, account, plan)
    end
  end
end
