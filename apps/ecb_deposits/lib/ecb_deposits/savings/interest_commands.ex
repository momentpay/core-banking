defmodule ECBDeposits.Savings.InterestCommands do
  @moduledoc """
  The two commands of an account that work interest out and post it: `calculateInterest` and `postInterest` (also
  `postInterestAsOn` on the transactions), after Fineract's `SavingsAccountWritePlatformServiceJpaRepositoryImpl`.
  Neither adds a transaction of its own but the postings of interest. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.{Balance, Interest, Postings, Transitions}
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @supported ~w(dateFormat locale transactionDate externalId isPostInterestAsOn postInterestManualOrAutomatic)

  @doc "Works the interest of account `id` out up to today and records what it has earned."
  @spec calculate!(struct, integer) :: Result.t()
  def calculate!(user, id) do
    account = Transitions.account!(id)
    plan = Interest.plan(account, Balance.live(id), precision: 15, mode: :calculate)
    Postings.settle!(user, account, plan)
    result(account)
  end

  @doc "Posts the interest of account `id` earned in the periods that have ended, or as on a date."
  @spec post!(struct, integer, Params.t()) :: Result.t()
  def post!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    validate!(p)

    as_on? =
      Params.boolean(p, "isPostInterestAsOn") == true or
        Params.boolean(p, "postInterestManualOrAutomatic") == true

    date = Params.date(p, "transactionDate")
    account = Transitions.account!(id)
    if as_on?, do: check_as_on_date!(account, date)

    if posts?(account) do
      opts = [precision: 10, mode: :post, as_on: as_on? && date]
      plan = Interest.plan(account, Balance.live(id), opts)
      applied = Postings.settle!(user, account, plan)
      external_id!(applied, Params.string(p, "externalId"), date)
    end

    result(account)
  end

  # Fineract posts nothing when the account earns no interest and is not overdrawn at interest
  defp posts?(account) do
    positive?(account.nominal_annual_interest_rate) or
      (account.allow_overdraft == true and
         positive?(account.nominal_annual_interest_rate_overdraft))
  end

  defp positive?(nil), do: false
  defp positive?(%Decimal{} = d), do: Decimal.gt?(d, 0)

  defp validate!(p) do
    Validation.new("savingsaccount.transaction")
    |> Validation.param("externalId", Params.string(p, "externalId"))
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> booleans(p)
    |> Validation.raise_if_errors!()
  end

  defp booleans(v, p) do
    Enum.reduce(~w(isPostInterestAsOn postInterestManualOrAutomatic), v, fn name, v ->
      if Params.exists?(p, name),
        do:
          v |> Validation.param(name, Params.boolean(p, name)) |> Validation.one_of([true, false]),
        else: v
    end)
  end

  defp check_as_on_date!(account, date) do
    cond do
      date == nil ->
        rule!("error.msg.nullDatePassed", "Please pass a valid date")

      Date.compare(date, activation_or_submission(account)) == :lt ->
        rule!(
          "error.msg.before activation date",
          "Post interest date must be after the activation date"
        )

      after_last_transaction?(account, date) ->
        rule!("error.msg.countInterest", "Cannot post interest before last transaction date")

      Date.compare(date, BusinessDate.current()) == :gt ->
        rule!("error.msg.futureDate", "Cannot post interest in future dates")

      true ->
        :ok
    end
  end

  defp activation_or_submission(account), do: account.activatedon_date || account.submittedon_date

  defp after_last_transaction?(account, date) do
    TenantRepo.exists?(
      from(t in "m_savings_account_transaction",
        where: t.savings_account_id == ^account.id and t.transaction_date > ^date
      )
    )
  end

  defp rule!(code, message),
    do: raise(DomainRuleViolation, code: code, message: message, args: [])

  # the external id of a manual posting goes on the last one made, or on the one of the date asked for
  defp external_id!(_applied, nil, _date), do: :ok

  defp external_id!(applied, external_id, date) do
    manual = Enum.filter(applied.created, &(&1.type == 3 and &1.manual == true))

    chosen =
      Enum.find(manual, &(date != nil and Date.compare(&1.date, date) == :eq)) ||
        List.last(manual)

    if chosen,
      do:
        TenantRepo.update_all(
          from(t in "m_savings_account_transaction", where: t.id == ^chosen.id),
          set: [external_id: external_id]
        )

    :ok
  end

  defp result(account),
    do:
      Result.new(
        resource_id: account.id,
        savings_id: account.id,
        office_id: account.client_office_id,
        client_id: account.client_id
      )
end
