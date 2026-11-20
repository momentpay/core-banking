defmodule ECBDeposits.DepositAccounts.RecurringTransactions do
  @moduledoc """
  Money into and out of a recurring deposit account and the interest it earns, after Fineract's
  `DepositAccountWritePlatformServiceJpaRepositoryImpl` (`depositToRDAccount`, `withdrawal`, `calculateInterest`,
  `postInterest`), `DepositAccountDomainServiceJpa.handleRDDeposit` and `RecurringDepositAccount`.

  A deposit is a deposit into any savings account (and is followed by the working out of the interest the account has
  earned), and then goes towards the installments that are not paid, the maturity amount is worked out again from what
  the account holds and what it still has to receive, and what is overdue is counted. A withdrawal is allowed only when
  the account says so. Interest is worked out and posted up to the day before the term ends, and no further.
  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.DepositAccounts
  alias ECBDeposits.DepositAccounts.{Maturity, Recurring, RecurringSubmit}
  alias ECBDeposits.Savings.{Balance, Blocks, Interest, Postings, Transactions, Transitions}
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors
  alias ECBPlatform.Errors.{PlatformApiDataValidation, PlatformServiceUnavailable}
  alias ECBPlatform.Params.DatePattern

  @resource "recurringdepositaccount"
  @payment_fields ~w(accountNumber checkNumber routingCode receiptNumber bankNumber)

  @supported ~w(locale dateFormat transactionDate transactionAmount paymentTypeId accountNumber checkNumber routingCode
                receiptNumber bankNumber amount accountId date submittedOnDate lienTransaction isManualTransaction
                chargesPaidByData accountNo note)

  # --- depositing -------------------------------------------------------------------------------------

  @doc "Deposits money into recurring deposit account `id`."
  @spec deposit!(struct, integer, Params.t()) :: Result.t()
  def deposit!(user, id, %Params{} = p) do
    req = request!(p)
    stored = RecurringSubmit.writable!(id)
    account = Transitions.account!(id)
    {detail_id, changes} = Postings.payment_detail!(p)

    Blocks.check_transaction!(account, :credit)
    Postings.check_open!(account, req, p, @resource)

    tx_id =
      Postings.add_tx!(user, engine(account, stored), 1, req, detail_id, up_to: up_to(stored))

    Postings.wake!(account)
    Postings.note!(user, account, tx_id, Params.string(p, "note"))

    after_deposit!(id, req)
    result(account, tx_id, changes)
  end

  # what a deposit goes on to do: pay the installments, project the maturity again and count what is overdue
  defp after_deposit!(id, req) do
    detail = DepositAccounts.recurring_detail(id)
    Recurring.pay_installments!(id, req.date, req.amount, detail.adjust_advance == true)
    account = DepositAccounts.fetch!(:recurring, id)
    rate = refresh_rate!(account)
    Recurring.reproject!(account, rate)
    Recurring.update_overdue!(id)
  end

  # --- withdrawing ------------------------------------------------------------------------------------

  @doc "Withdraws money from recurring deposit account `id`, when the account allows withdrawals."
  @spec withdraw!(struct, integer, Params.t()) :: Result.t()
  def withdraw!(user, id, %Params{} = p) do
    req = request!(p)
    {detail_id, changes} = Postings.payment_detail!(p)
    stored = RecurringSubmit.writable!(id)
    account = Transitions.account!(id)

    Blocks.check_transaction!(account, :debit)

    if DepositAccounts.recurring_detail(id).allow_withdrawal != true do
      raise PlatformServiceUnavailable,
        code: "error.msg.recurringdepositaccount.account.trasaction.withdraw.notallowed",
        message:
          "Recurring Depositaccount withdraw transaction not allowed with account identifier #{id}",
        args: [id]
    end

    Postings.check_open!(account, req, p, @resource)
    Postings.check_lock_in!(account, req, p)

    tx_id =
      Postings.add_tx!(user, engine(account, stored), 2, req, detail_id,
        up_to: up_to(stored),
        check: [force?: false, amount: req.amount, hold: account.savings_on_hold]
      )

    Postings.wake!(account)
    Postings.note!(user, account, tx_id, Params.string(p, "note"))
    result(account, tx_id, changes)
  end

  # --- undoing and changing a transaction ----------------------------------------------------------------

  @doc """
  Undoes a deposit or a withdrawal. A deposit that is undone no longer pays its installments: they are paid again
  from the deposits that are left. What the account will come to and what is overdue are worked out again.
  """
  @spec undo!(struct, integer, integer) :: Result.t()
  def undo!(user, id, tx_id) do
    stored = RecurringSubmit.writable!(id)
    account = Transitions.account!(id)
    tx = Transactions.get(id, tx_id) || raise(Transactions.not_found(id, tx_id))
    Postings.check_active_for!(account, "undotransaction")
    engine = engine(account, stored)

    if tx.is_reversed == true do
      Postings.check_balance_after!(engine, Balance.live(id), "undotransaction")
    else
      Postings.remove_tx!(user, engine, tx, "undotransaction",
        precision: 15,
        up_to: up_to(stored)
      )
    end

    after_change!(id, tx.transaction_type_enum == 1)
    result(account, id, nil)
  end

  @doc "Changes a deposit or a withdrawal: undoes it and makes the one asked for."
  @spec adjust!(struct, integer, integer, Params.t()) :: Result.t()
  def adjust!(user, id, tx_id, %Params{} = p) do
    req = request!(p)
    tx = Transactions.get(id, tx_id) || raise(Transactions.not_found(id, tx_id))

    if tx.transaction_type_enum not in [1, 2] or tx.is_reversed == true,
      do: raise(Postings.update_not_allowed(id, tx_id))

    stored = RecurringSubmit.writable!(id)
    account = Transitions.account!(id)
    Postings.check_active_for!(account, "adjusttransaction")
    {detail_id, changes} = Postings.payment_detail!(p)

    if tx.transaction_type_enum == 1,
      do: deposit_rules!(stored, req, p),
      else: Postings.check_lock_in!(account, req, p)

    Postings.check_open!(account, req, p, @resource)

    new_id =
      Postings.replace_tx!(user, engine(account, stored), tx, req, detail_id,
        up_to: up_to(stored)
      )

    after_change!(id, tx.transaction_type_enum == 1)
    result(account, new_id, changes)
  end

  # what `RecurringDepositAccount.deposit` asks of a deposit that replaces another (a new one does not meet them)
  defp deposit_rules!(%{term: term} = stored, req, p) do
    pattern = Params.date_format(p)
    text = DatePattern.format(req.date, pattern)

    cond do
      term.maturity_date != nil and Date.compare(req.date, term.maturity_date) != :lt ->
        date_problem!(
          "error.msg.recurring.deposit.account.transaction.date.is.after.account.maturity.date",
          "Transaction is not allowed. Transaction date is on or after account maturity date.",
          text
        )

      Date.compare(req.date, start(stored)) == :lt ->
        date_problem!(
          "error.msg.recurring.deposit.account.transaction.date.is.before.account.activation.or.deposit.date",
          "Transaction is not allowed. Transaction date is on or after account activation and deposit start date.",
          text
        )

      true ->
        :ok
    end
  end

  defp date_problem!(code, message, text) do
    raise PlatformApiDataValidation,
      errors: [Errors.parameter_error(code, message, "transactionDate", [text])]
  end

  # after a transaction is undone or changed: a deposit's installments are paid again from the deposits that are left,
  # and the maturity and what is overdue are worked out
  defp after_change!(id, deposit?) do
    account = DepositAccounts.fetch!(:recurring, id)
    detail = DepositAccounts.recurring_detail(id)
    if deposit?, do: Recurring.replay!(id, detail.adjust_advance == true)
    Recurring.reproject!(account, refresh_rate!(account))
    Recurring.update_overdue!(id)
  end

  # --- the amount asked of each installment ----------------------------------------------------------------

  @doc """
  Changes the amount each installment asks for, from the installments due on the day given. Installments before it keep
  theirs; every deposit is put towards them again.
  """
  @spec update_deposit_amount!(struct, integer, Params.t()) :: Result.t()
  def update_deposit_amount!(_user, id, %Params{} = p) do
    Params.check_supported!(
      p,
      ~w(locale dateFormat mandatoryRecommendedDepositAmount effectiveDate)
    )

    effective = Params.date(p, "effectiveDate")
    amount = Params.decimal_with_locale(p, "mandatoryRecommendedDepositAmount")

    "savingsaccount"
    |> Validation.new()
    |> Validation.param("effectiveDate", effective)
    |> Validation.not_null()
    |> Validation.param("mandatoryRecommendedDepositAmount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.raise_if_errors!()

    stored = RecurringSubmit.writable!(id)
    client = ECBParty.Clients.fetch!(stored.client_id)
    require_active!(stored)

    TenantRepo.update_all(
      from(d in "m_deposit_account_recurring_detail", where: d.savings_account_id == ^id),
      set: [mandatory_recommended_deposit_amount: amount]
    )

    Recurring.new_amount!(id, effective, amount)
    after_change!(id, true)

    Result.new(
      resource_id: id,
      savings_id: id,
      office_id: client.office_id,
      client_id: client.id,
      changes: %{"mandatoryRecommendedDepositAmount" => amount}
    )
  end

  defp require_active!(%{status_enum: 300}), do: :ok

  defp require_active!(_stored) do
    raise PlatformApiDataValidation,
      errors: [
        Errors.parameter_error(
          "error.msg.recurringdepositaccount.is.not.active",
          "Updates to the recommended deposit amount are allowed only when the underlying account is active.",
          nil,
          []
        )
      ]
  end

  # --- the interest ------------------------------------------------------------------------------------

  @doc "`calculateInterest`: works the interest out up to today (or the last day of the term)."
  @spec calculate!(struct, integer) :: Result.t()
  def calculate!(user, id) do
    stored = RecurringSubmit.writable!(id)
    account = Transitions.account!(id)

    if earning?(stored) do
      rate = refresh_rate!(stored)
      account = engine(%{account | nominal_annual_interest_rate: rate}, stored)

      plan =
        Interest.plan(account, Balance.live(id),
          precision: 15,
          mode: :calculate,
          up_to: up_to(stored)
        )

      Postings.settle!(user, account, plan)
    end

    result(account, id, nil)
  end

  @doc "`postInterest`: posts the interest of the posting periods that have ended."
  @spec post!(struct, integer) :: Result.t()
  def post!(user, id) do
    stored = RecurringSubmit.writable!(id)
    account = Transitions.account!(id)

    if earning?(stored) do
      rate = refresh_rate!(stored)
      account = engine(%{account | nominal_annual_interest_rate: rate}, stored)

      plan =
        Interest.plan(account, Balance.live(id), precision: 10, mode: :post, up_to: up_to(stored))

      Postings.settle!(user, account, plan)
    end

    result(account, id, nil)
  end

  # active, or matured and not yet closed
  defp earning?(account), do: account.status_enum in [300, 800]

  # --- what the engine needs of the account ------------------------------------------------------------

  # the day interest starts: the first day of deposit, or the day the account was activated
  defp engine(account, stored),
    do: %{account | start_interest_calculation_date: start(stored)}

  defp start(%{term: term} = stored),
    do: term.expected_first_deposit_on || stored.activatedon_date || stored.submittedon_date

  # interest stops the day before the term ends
  defp up_to(%{term: %{maturity_date: nil}}), do: BusinessDate.current()

  defp up_to(%{term: %{maturity_date: maturity}}) do
    last = Date.add(maturity, -1)
    today = BusinessDate.current()
    if Date.compare(today, last) == :gt, do: last, else: today
  end

  @doc """
  The rate the account earns: that of its chart for what it is to deposit (as stored) over the whole term, as Fineract
  works it out whenever interest is. It is kept on the account.
  """
  @spec refresh_rate!(map) :: Decimal.t()
  def refresh_rate!(account) do
    term = account.term

    rate =
      case DepositAccounts.chart(account.id) do
        nil ->
          account.nominal_annual_interest_rate

        chart ->
          Maturity.rate(chart.slabs, term.deposit_amount, start(account), term.maturity_date)
      end

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account.id),
      set: [nominal_annual_interest_rate: rate]
    )

    rate
  end

  # --- the request --------------------------------------------------------------------------------------

  defp request!(p) do
    Params.check_supported!(p, @supported)
    date = Params.date(p, "transactionDate")
    amount = Params.decimal_with_locale(p, "transactionAmount")
    type_id = Params.integer_with_locale(p, "paymentTypeId")

    @resource
    |> Validation.new()
    |> Validation.param("transactionDate", date)
    |> Validation.not_null()
    |> Validation.param("transactionAmount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.param("paymentTypeId", type_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> payment_lengths(p)
    |> Validation.raise_if_errors!()

    %{date: date, amount: amount, external_id: nil}
  end

  defp payment_lengths(v, p) do
    Enum.reduce(@payment_fields, v, fn name, v ->
      v
      |> Validation.param(name, Params.string(p, name))
      |> Validation.ignore_if_null()
      |> Validation.max_length(50)
    end)
  end

  defp result(account, id, changes) do
    Result.new(
      resource_id: id,
      savings_id: account.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      changes: changes
    )
  end
end
