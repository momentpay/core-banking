defmodule ECBDeposits.DepositAccounts.Closing do
  @moduledoc """
  Closing a fixed deposit account, after Fineract's `DepositAccountDomainServiceJpa.handleFDAccountClosure` and
  `handleFDAccountPreMatureClosure` and `FixedDepositAccount.close` and `prematureClosure`: closing early (the interest
  earned is posted at the rate the penalty leaves, the balance is withdrawn and the account is premature closed) and
  closing a matured deposit (the interest of the whole term is posted, the balance is withdrawn and the account is
  closed). The money leaves in a withdrawal; paying it into a savings account and investing it again are refused as
  not supported yet. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.DepositAccounts.FixedInterest
  alias ECBDeposits.{Savings, SavingsEnums}
  alias ECBDeposits.Savings.{Postings, Transitions}
  alias ECBPlatform.{BusinessDate, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.Params.DatePattern

  @active 300
  @closed 600
  @premature 700
  @matured 800
  @withdraw 100
  @transfer 200
  @payment_fields ~w(accountNumber checkNumber routingCode receiptNumber bankNumber)

  @supported ~w(locale dateFormat closedOnDate note onAccountClosureId paymentTypeId accountNumber checkNumber
                routingCode receiptNumber bankNumber transferDescription toSavingsAccountId)

  @doc "The parameters `calculatePrematureAmount` takes."
  @spec amount_parameters() :: [String.t()]
  def amount_parameters, do: ~w(locale dateFormat closedOnDate)

  # --- the premature amount -------------------------------------------------------------------------

  @doc "The amount the deposit would pay if it were closed early on the day in `p`."
  @spec premature_amount!(integer, Params.t()) :: map
  def premature_amount!(id, %Params{} = p) do
    Params.check_supported!(p, amount_parameters())
    on = Params.date(p, "closedOnDate")

    "fixeddepositaccount"
    |> Validation.new()
    |> Validation.param("closedOnDate", on)
    |> Validation.not_null()
    |> Validation.raise_if_errors!()

    account = ECBDeposits.DepositAccounts.Submit.writable!(id)
    %{account: account, amount: FixedInterest.premature_amount(account, on)}
  end

  # --- closing early --------------------------------------------------------------------------------

  @doc "`prematureClose`: closes an active deposit before it matures."
  @spec premature_close!(struct, integer, Params.t()) :: Result.t()
  def premature_close!(user, id, %Params{} = p) do
    request = request!(p, true)
    account = FixedInterest.fixed!(id)
    refuse_unsupported!(request)

    FixedInterest.post_premature_interest!(user, account, request.on)
    account = fresh(id, :normal)

    changes =
      Postings.closing_withdrawal!(user, account, p, request.on, withdrawal_options(account))

    if Savings.fetch!(id).status_enum != @active,
      do: failure!("preMatureClose", nil, "not.in.active.state", nil)

    check_last_transaction!(id, request.on, "preMatureClose")
    close_account!(user, id, request, @premature)
    finish(user, account, p, request, changes, @premature)
  end

  # --- closing at maturity --------------------------------------------------------------------------

  @doc "`close`: closes a deposit that has matured, paying out the balance."
  @spec close!(struct, integer, Params.t()) :: Result.t()
  def close!(user, id, %Params{} = p) do
    request = request!(p, false)
    account = FixedInterest.fixed!(id)
    refuse_unsupported!(request)

    FixedInterest.post_maturity_interest!(user, account)
    account = fresh(id, :normal)

    changes =
      Postings.closing_withdrawal!(user, account, p, request.on, withdrawal_options(account))

    check_closable!(account, request.on)
    close_account!(user, id, request, @closed)
    finish(user, account, p, request, changes, @closed)
  end

  # the deposit as it is, earning the rate of its chart
  defp fresh(id, mode) do
    ECBDeposits.DepositAccounts.fetch!(:fixed, id) |> FixedInterest.with_rate!(mode)
  end

  # a matured deposit can be taken from, and what it earns stops at the end of its term
  defp withdrawal_options(account) do
    [
      up_to: earliest(BusinessDate.current(), FixedInterest.last_day(account)),
      post_until: BusinessDate.current(),
      cap_dates: account.status_enum == @matured,
      check: [
        force?: false,
        amount: account.account_balance_derived,
        hold: account.savings_on_hold
      ],
      as: if(account.status_enum == @matured, do: %{status_enum: @active}, else: %{})
    ]
  end

  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(Date.compare(a, b) == :gt, do: b, else: a)

  # --- the request ----------------------------------------------------------------------------------

  defp request!(p, premature?) do
    Params.check_supported!(p, @supported)
    on = Params.date(p, "closedOnDate")
    closure = Params.integer(p, "onAccountClosureId")
    to_savings = Json.long(p, "toSavingsAccountId")
    type_id = Params.integer_with_locale(p, "paymentTypeId")

    "fixeddepositaccount"
    |> Validation.new()
    |> Validation.param("closedOnDate", on)
    |> Validation.not_null()
    |> Validation.param("onAccountClosureId", closure)
    |> Validation.not_blank()
    |> Validation.one_of([100, 200, 300, 400])
    |> closure_rules(closure, to_savings, premature?)
    |> Validation.param("paymentTypeId", type_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> detail_lengths(p)
    |> Validation.raise_if_errors!()

    %{on: on, closure: closure, to_savings: to_savings, note: Params.string(p, "note")}
  end

  defp closure_rules(v, @transfer, to_savings, _premature?) do
    v
    |> Validation.param("toSavingsAccountId", to_savings)
    |> Validation.must_be_provided_when(
      "onAccountClosureId",
      "depositAccountClosureType.transferToSavings"
    )
  end

  defp closure_rules(v, closure, _to_savings, true) when closure in [300, 400] do
    v
    |> Validation.param("onAccountClosureId", closure)
    |> Validation.fail_with_code("reinvest.not.allowed", [
      "Re-Invest is not supported for account pre mature close"
    ])
  end

  defp closure_rules(v, _closure, _to_savings, _premature?), do: v

  defp detail_lengths(v, p) do
    Enum.reduce(@payment_fields, v, fn name, v ->
      v
      |> Validation.param(name, Params.string(p, name))
      |> Validation.ignore_if_null()
      |> Validation.max_length(50)
    end)
  end

  # paying into a savings account and investing again are not built yet
  defp refuse_unsupported!(%{closure: @transfer, to_savings: id}) do
    Savings.fetch!(id)

    unsupported!(
      "Paying a deposit into a savings account when it is closed is",
      "toSavingsAccountId"
    )
  end

  defp refuse_unsupported!(%{closure: closure}) when closure in [300, 400],
    do: unsupported!("Investing a deposit again when it is closed is", "onAccountClosureId")

  defp refuse_unsupported!(%{closure: @withdraw}), do: :ok

  defp unsupported!(what, parameter) do
    raise DomainRuleViolation,
      code: "error.msg.depositaccount.feature.not.supported.yet",
      message: "#{what} not supported yet by E-CoreBank: #{parameter}",
      args: [parameter]
  end

  # --- the rules of the account ---------------------------------------------------------------------

  # `FixedDepositAccount.close`: after the withdrawal, the deposit has to be matured and the day a fitting one
  defp check_closable!(account, on) do
    fresh = Savings.fetch!(account.id)
    term = ECBDeposits.DepositAccounts.term(account.id)

    if fresh.status_enum != @matured, do: failure!("close", nil, "not.in.matured.state", nil)

    cond do
      Date.compare(on, fresh.activatedon_date) == :lt ->
        code_failure!("close", "must.be.after.activation.date", on)

      term.maturity_date != nil and Date.compare(on, term.maturity_date) == :lt ->
        code_failure!("close", "must.be.after.account.maturity.date", on)

      Date.compare(on, BusinessDate.current()) == :gt ->
        code_failure!("close", "cannot.be.a.future.date", on)

      true ->
        check_last_transaction!(account.id, on, "close")
    end
  end

  # nothing may have happened after the day of closing
  defp check_last_transaction!(id, on, action) do
    last = Postings.last_transaction_date(id)

    if last != nil and Date.compare(last, on) == :gt,
      do: code_failure!(action, "must.be.after.last.transaction.date", on)

    :ok
  end

  defp failure!(action, parameter, code, value) do
    ("fixeddepositaccount." <> action)
    |> Validation.new()
    |> then(&if(parameter, do: Validation.param(&1, parameter, value), else: &1))
    |> Validation.fail_without_parameter(code)
    |> Validation.raise_if_errors!()
  end

  defp code_failure!(action, code, on) do
    ("fixeddepositaccount." <> action)
    |> Validation.new()
    |> Validation.param("closedOnDate", on)
    |> Validation.fail_with_code(code)
    |> Validation.raise_if_errors!()
  end

  # --- closing --------------------------------------------------------------------------------------

  defp close_account!(user, id, request, status) do
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [
        status_enum: status,
        rejectedon_date: nil,
        rejectedon_userid: nil,
        withdrawnon_date: nil,
        withdrawnon_userid: nil,
        closedon_date: request.on,
        closedon_userid: user.id,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    TenantRepo.update_all(
      from(t in "m_deposit_account_term_and_preclosure", where: t.savings_account_id == ^id),
      set: [on_account_closure_enum: request.closure]
    )
  end

  defp finish(user, account, p, request, changes, status) do
    Transitions.note!(account, request.note, user, 500)

    changes =
      changes
      |> Map.put("status", SavingsEnums.account_status(status))
      |> Map.put("locale", Params.string(p, "locale"))
      |> Map.put("dateFormat", Params.string(p, "dateFormat"))
      |> Map.put("closedOnDate", DatePattern.format(request.on, Params.date_format(p)))
      |> put_note(request.note)

    client = ECBParty.Clients.fetch!(account.client_id)

    Result.new(
      resource_id: account.id,
      savings_id: account.id,
      office_id: client.office_id,
      client_id: client.id,
      changes: changes
    )
  end

  defp put_note(changes, note),
    do:
      if(note != nil and String.trim(note) != "",
        do: Map.put(changes, "note", note),
        else: changes
      )
end
