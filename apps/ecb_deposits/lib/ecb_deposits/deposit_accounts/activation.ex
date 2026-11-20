defmodule ECBDeposits.DepositAccounts.Activation do
  @moduledoc """
  Activating a fixed deposit account, after Fineract's `DepositAccountWritePlatformServiceJpaRepositoryImpl.activateFDAccount`
  and `SavingsAccount.activate`. The deposit the application promised is made on the day of activation; the maturity
  date and amount are worked out again from that day. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.{DepositAccounts, SavingsEnums}
  alias ECBDeposits.DepositAccounts.Maturity
  alias ECBDeposits.Savings.Postings
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Params.DatePattern

  @approved 200
  @active 300

  @doc "Activates an approved fixed deposit account."
  @spec activate!(struct, integer, Params.t()) :: Result.t()
  def activate!(user, id, %Params{} = p) do
    Params.check_supported!(p, ~w(locale dateFormat activatedOnDate))
    on = Params.date(p, "activatedOnDate")

    "savingsaccount"
    |> Validation.new()
    |> Validation.param("activatedOnDate", on)
    |> Validation.not_null()
    |> Validation.raise_if_errors!()

    account = ECBDeposits.DepositAccounts.Submit.writable!(id)
    client = Clients.fetch!(account.client_id)

    if client.status_enum != Clients.status(:active),
      do: ECBDeposits.Savings.Submit.not_active!(client.id)

    require_approved!(account)
    checks!(account, on, p)

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [
        status_enum: @active,
        rejectedon_date: nil,
        rejectedon_userid: nil,
        withdrawnon_date: nil,
        withdrawnon_userid: nil,
        closedon_date: nil,
        closedon_userid: nil,
        activatedon_date: on,
        activatedon_userid: user.id,
        start_interest_calculation_date: on,
        lockedin_until_date_derived: locked_until(account, on),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    deposit = account.term.deposit_amount

    if deposit != nil and Decimal.gt?(deposit, 0),
      do: Postings.opening_deposit!(user, ECBDeposits.Savings.fetch!(id), on, deposit)

    mature!(id, on)
    ECBDeposits.DepositAccounts.FixedInterest.store_end!(id, BusinessDate.current())

    # the projection to maturity leaves nothing earned on the account's summary until interest is asked for
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [total_interest_earned_derived: nil, last_interest_calculation_date: nil]
    )

    Result.new(
      resource_id: id,
      savings_id: id,
      office_id: client.office_id,
      client_id: client.id,
      changes: %{
        "status" => SavingsEnums.account_status(@active),
        "locale" => Params.locale(p),
        "dateFormat" => Params.date_format(p),
        "activatedOnDate" => DatePattern.format(on, Params.date_format(p))
      }
    )
  end

  @doc "Works the maturity date and amount of a fixed deposit out again from the day it started."
  @spec mature!(integer, Date.t()) :: :ok
  def mature!(id, start) do
    account = DepositAccounts.fetch!(:fixed, id)
    term = account.term
    maturity = Maturity.date(start, term.deposit_period, term.deposit_period_frequency)
    chart = DepositAccounts.chart(id)

    rate =
      if chart,
        do: Maturity.rate(chart.slabs, term.deposit_amount, start, maturity),
        else: account.nominal_annual_interest_rate

    amount =
      Maturity.amount(%{
        start: start,
        maturity: maturity,
        amount: term.deposit_amount,
        rate: rate,
        posting: account.interest_posting_period_enum,
        compounding: account.interest_compounding_period_enum,
        calculation: account.interest_calculation_type_enum,
        days_in_year: account.interest_calculation_days_in_year_type_enum,
        min_balance: account.min_balance_for_interest_calculation,
        decimals: account.currency_digits
      })

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [nominal_annual_interest_rate: rate]
    )

    TenantRepo.update_all(
      from(t in "m_deposit_account_term_and_preclosure", where: t.savings_account_id == ^id),
      set: [maturity_date: maturity, maturity_amount: amount]
    )

    :ok
  end

  defp require_approved!(%{status_enum: @approved}), do: :ok

  defp require_approved!(_account) do
    "fixeddepositaccount.activate"
    |> Validation.new()
    |> Validation.param("activatedOnDate", nil)
    |> Validation.fail_without_parameter("not.in.approved.state")
    |> Validation.raise_if_errors!()
  end

  defp checks!(account, on, p) do
    pattern = Params.date_format(p)

    cond do
      account.client_activation_date && Date.compare(account.client_activation_date, on) == :gt ->
        problem!(
          "cannot.be.before.client.activation.date",
          DatePattern.format(account.client_activation_date, pattern)
        )

      Date.compare(on, account.approvedon_date) == :lt ->
        problem!(
          "cannot.be.before.approval.date",
          DatePattern.format(account.approvedon_date, pattern)
        )

      Date.compare(on, BusinessDate.current()) == :gt ->
        problem!("cannot.be.a.future.date", on)

      true ->
        :ok
    end
  end

  defp problem!(code, value) do
    "fixeddepositaccount.activate"
    |> Validation.new()
    |> Validation.param("activatedOnDate", value)
    |> Validation.fail_without_parameter(code)
    |> Validation.raise_if_errors!()
  end

  # the day an account with a lock-in period is no longer locked in
  defp locked_until(%{lockin_period_frequency: nil}, _on), do: nil

  defp locked_until(%{lockin_period_frequency: frequency, lockin_period_frequency_enum: type}, on) do
    n = Decimal.to_integer(frequency)

    case type do
      0 -> Date.add(on, n)
      1 -> Date.add(on, n * 7)
      2 -> Date.shift(on, month: n)
      3 -> Date.shift(on, year: n)
      _ -> nil
    end
  end
end
