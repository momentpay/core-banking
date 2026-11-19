defmodule ECBDeposits.Savings.Transitions do
  @moduledoc """
  The steps of a savings account's life that are not money: approving the application, taking the approval back,
  rejecting it, the applicant withdrawing it, activating the account and closing it. After Fineract's
  `SavingsAccount` (`approveApplication`, `undoApplicationApproval`, `rejectApplication`,
  `applicantWithdrawsFromApplication`, `activate`, `close`) and `SavingsApplicationProcessWritePlatformServiceJpaRepositoryImpl`.
  """
  import Ecto.Query

  alias ECBDeposits.{Savings, SavingsEnums}
  alias ECBDeposits.Savings.Postings
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.Params.DatePattern

  @pending 100
  @approved 200
  @active 300
  @withdrawn 400
  @rejected 500
  @closed 600

  @dated ~w(locale dateFormat note)

  # --- approving, rejecting, withdrawing -----------------------------------------------------------

  @doc "Approves an application."
  @spec approve!(struct, integer, Params.t()) :: Result.t()
  def approve!(user, id, %Params{} = p) do
    {on, note} = application_request!(p, "approvedOnDate")
    account = account!(id)

    require_status!(
      account,
      @pending,
      "approval",
      "approvedOnDate",
      "not.in.submittedandpendingapproval.state"
    )

    date_checks!(account, "approval", "approvedOnDate", on, p, nil)

    update!(id, user,
      status_enum: @approved,
      approvedon_date: on,
      approvedon_userid: user.id
    )

    note!(account, note, user, 500)

    changes =
      %{"status" => SavingsEnums.account_status(@approved)}
      |> put_request(p, "approvedOnDate")
      |> put_note(note)

    result(account, changes)
  end

  @doc "Rejects an application."
  @spec reject!(struct, integer, Params.t()) :: Result.t()
  def reject!(user, id, %Params{} = p) do
    {on, note} = application_request!(p, "rejectedOnDate")
    account = account!(id)

    require_status!(
      account,
      @pending,
      "reject",
      "rejectedOnDate",
      "not.in.submittedandpendingapproval.state"
    )

    date_checks!(account, "reject", "rejectedOnDate", on, p, on)

    update!(id, user,
      status_enum: @rejected,
      rejectedon_date: on,
      rejectedon_userid: user.id,
      withdrawnon_date: nil,
      withdrawnon_userid: nil,
      closedon_date: on,
      closedon_userid: user.id
    )

    note!(account, note, user, 500)

    changes =
      %{"status" => SavingsEnums.account_status(@rejected)}
      |> put_request(p, "rejectedOnDate")
      |> Map.put("closedOnDate", Params.string(p, "rejectedOnDate"))
      |> put_note(note)

    result(account, changes)
  end

  @doc "Withdraws an application at the applicant's request."
  @spec withdraw!(struct, integer, Params.t()) :: Result.t()
  def withdraw!(user, id, %Params{} = p) do
    {on, note} = application_request!(p, "withdrawnOnDate")
    account = account!(id)

    require_status!(
      account,
      @pending,
      "withdrawnByApplicant",
      "withdrawnOnDate",
      "not.in.submittedandpendingapproval.state"
    )

    date_checks!(account, "withdrawnByApplicant", "withdrawnOnDate", on, p, on)

    update!(id, user,
      status_enum: @withdrawn,
      rejectedon_date: nil,
      rejectedon_userid: nil,
      withdrawnon_date: on,
      withdrawnon_userid: user.id,
      closedon_date: on,
      closedon_userid: user.id
    )

    note!(account, note, user, 500)

    changes =
      %{"status" => SavingsEnums.account_status(@withdrawn)}
      |> put_request(p, "withdrawnOnDate")
      |> Map.put("closedOnDate", Params.string(p, "withdrawnOnDate"))
      |> put_note(note)

    result(account, changes)
  end

  @doc "Takes the approval of an application back."
  @spec undo_approval!(struct, integer, Params.t()) :: Result.t()
  def undo_approval!(user, id, %Params{} = p) do
    Params.check_supported!(p, ["note"])
    note = Params.string(p, "note")

    Validation.new("savingsaccountapplication.undo")
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.raise_if_errors!()

    account = account!(id)
    require_status!(account, @approved, "undoApproval", "approvedOnDate", "not.in.approved.state")

    update!(id, user,
      status_enum: @pending,
      approvedon_date: nil,
      approvedon_userid: nil,
      rejectedon_date: nil,
      rejectedon_userid: nil,
      withdrawnon_date: nil,
      withdrawnon_userid: nil,
      closedon_date: nil,
      closedon_userid: nil
    )

    note!(account, note, user, 500)

    changes =
      %{"status" => SavingsEnums.account_status(@pending), "approvedOnDate" => ""}
      |> put_note(note)

    result(account, changes)
  end

  # --- activating and closing ---------------------------------------------------------------------

  @doc "Activates an approved account."
  @spec activate!(struct, integer, Params.t()) :: Result.t()
  def activate!(user, id, %Params{} = p) do
    Params.check_supported!(p, ~w(locale dateFormat activatedOnDate))
    on = Params.date(p, "activatedOnDate")

    Validation.new("savingsaccount")
    |> Validation.param("activatedOnDate", on)
    |> Validation.not_null()
    |> Validation.raise_if_errors!()

    account = account!(id)
    require_status!(account, @approved, "activate", "activatedOnDate", "not.in.approved.state")
    activation_checks!(account, on, p)

    update!(id, user,
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
      lockedin_until_date_derived: locked_until(account, on)
    )

    opening = account.min_required_opening_balance

    if opening != nil and Decimal.gt?(opening, 0),
      do: Postings.opening_deposit!(user, Savings.fetch!(id), on, opening)

    changes =
      %{"status" => SavingsEnums.account_status(@active)}
      |> put_request(p, "activatedOnDate")

    result(account, changes)
  end

  defp activation_checks!(account, on, p) do
    pattern = Params.date_format(p)

    cond do
      account.client_activation_date && Date.compare(account.client_activation_date, on) == :gt ->
        error!(
          "activate",
          "activatedOnDate",
          "cannot.be.before.client.activation.date",
          DatePattern.format(account.client_activation_date, pattern)
        )

      Date.compare(on, account.approvedon_date) == :lt ->
        error!(
          "activate",
          "activatedOnDate",
          "cannot.be.before.approval.date",
          DatePattern.format(account.approvedon_date, pattern)
        )

      Date.compare(on, BusinessDate.current()) == :gt ->
        error!("activate", "activatedOnDate", "cannot.be.a.future.date", on)

      true ->
        :ok
    end
  end

  # the day the account is no longer locked in, when it has a lock-in period
  defp locked_until(%{lockin_period_frequency: nil}, _on), do: nil

  defp locked_until(%{lockin_period_frequency: frequency, lockin_period_frequency_enum: type}, on) do
    n = frequency |> Decimal.to_integer()

    case type do
      0 -> Date.add(on, n)
      1 -> Date.add(on, n * 7)
      2 -> Date.shift(on, month: n)
      3 -> Date.shift(on, year: n)
      _ -> nil
    end
  end

  @close_supported ~w(locale dateFormat closedOnDate note paymentTypeId withdrawBalance accountNumber checkNumber
                      routingCode receiptNumber bankNumber postInterestValidationOnClosure)

  @doc "Closes an active account."
  @spec close!(struct, integer, Params.t()) :: Result.t()
  def close!(user, id, %Params{} = p) do
    Params.check_supported!(p, @close_supported)
    account = account!(id)
    on = Params.date(p, "closedOnDate")
    withdraw = Params.boolean(p, "withdrawBalance")
    type_id = Params.integer_with_locale(p, "paymentTypeId")

    Validation.new("savingsaccount")
    |> Validation.param("closedOnDate", on)
    |> Validation.not_null()
    |> then(
      &if(Params.exists?(p, "withdrawBalance"),
        do:
          &1 |> Validation.param("withdrawBalance", withdraw) |> Validation.one_of([true, false]),
        else: &1
      )
    )
    |> Postings.payment_type_details(p, type_id)
    |> Validation.raise_if_errors!()

    {account, changes} = withdraw_balance!(user, account, p, on, withdraw == true)
    check_closable!(account, on)

    update!(id, user,
      status_enum: @closed,
      rejectedon_date: nil,
      rejectedon_userid: nil,
      withdrawnon_date: nil,
      withdrawnon_userid: nil,
      closedon_date: on,
      closedon_userid: user.id
    )

    note = Params.string(p, "note")
    note!(account, note, user, 500)

    changes =
      changes
      |> Map.put("status", SavingsEnums.account_status(@closed))
      |> put_request(p, "closedOnDate")
      |> put_note(note)

    result(account, changes)
  end

  # Fineract takes what is left out of the account first, then closes it
  defp withdraw_balance!(user, account, p, on, true) do
    if Decimal.gt?(account.account_balance_derived, 0) do
      changes = Postings.closing_withdrawal!(user, account, p, on)
      {Savings.fetch!(account.id), changes}
    else
      {account, %{}}
    end
  end

  defp withdraw_balance!(_user, account, _p, _on, false), do: {account, %{}}

  defp check_closable!(account, on) do
    if account.status_enum != @active, do: error!("close", nil, "not.in.active.state", nil)

    cond do
      Date.compare(on, account.activatedon_date) == :lt ->
        code_error!("close", "closedOnDate", "must.be.after.activation.date", on)

      Date.compare(on, BusinessDate.current()) == :gt ->
        code_error!("close", "closedOnDate", "cannot.be.a.future.date", on)

      true ->
        :ok
    end

    last = Postings.last_transaction_date(account.id)

    if last != nil and Date.compare(last, on) == :gt,
      do: code_error!("close", "closedOnDate", "must.be.after.last.transaction.date", on)

    if not Decimal.eq?(account.account_balance_derived, 0),
      do: error!("close", nil, "results.in.balance.not.zero", nil)
  end

  # --- shared ---------------------------------------------------------------------------------------

  defp application_request!(p, date_key) do
    Params.check_supported!(p, [date_key | @dated])
    on = Params.date(p, date_key)
    note = Params.string(p, "note")

    Validation.new("savingsaccountapplication")
    |> Validation.param(date_key, on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.raise_if_errors!()

    {on, note}
  end

  @doc false
  @spec account!(integer) :: map
  def account!(id) do
    account = Savings.fetch!(id)

    if account.client_id do
      client = Clients.fetch!(account.client_id)

      if client.status_enum != Clients.status(:active) do
        raise DomainRuleViolation,
          code: "error.msg.client.not.active.exception",
          message: "The Client with id `#{client.id}` is not active",
          args: [client.id]
      end
    end

    account
  end

  defp require_status!(account, status, action, parameter, code) do
    if account.status_enum != status, do: error!(action, parameter, code, nil)
  end

  # the date of approving, rejecting or withdrawing: not before the application, not in the future
  defp date_checks!(account, action, parameter, on, p, future_value) do
    cond do
      Date.compare(on, account.submittedon_date) == :lt ->
        error!(
          action,
          parameter,
          "cannot.be.before.submittal.date",
          DatePattern.format(account.submittedon_date, Params.date_format(p))
        )

      Date.compare(on, BusinessDate.current()) == :gt ->
        error!(action, parameter, "cannot.be.a.future.date", future_value)

      true ->
        :ok
    end
  end

  # Fineract's `failWithCodeNoParameterAddedToErrorCode`: the code is `validation.msg.savingsaccount.<action>.<code>`
  defp error!(action, parameter, code, value) do
    Validation.new("savingsaccount." <> action)
    |> then(&if parameter, do: Validation.param(&1, parameter, value), else: &1)
    |> Validation.fail_without_parameter(code)
    |> Validation.raise_if_errors!()
  end

  # and `failWithCode`, which puts the parameter into the code too
  defp code_error!(action, parameter, code, value) do
    Validation.new("savingsaccount." <> action)
    |> Validation.param(parameter, value)
    |> Validation.fail_with_code(code)
    |> Validation.raise_if_errors!()
  end

  defp update!(id, user, set) do
    set = set ++ [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id), set: set)
  end

  defp put_request(changes, p, date_key) do
    changes
    |> Map.put("locale", Params.string(p, "locale"))
    |> Map.put("dateFormat", Params.string(p, "dateFormat"))
    |> Map.put(date_key, Params.string(p, date_key))
  end

  defp put_note(changes, note),
    do:
      if(note != nil and String.trim(note) != "",
        do: Map.put(changes, "note", note),
        else: changes
      )

  defp note!(_account, nil, _user, _type), do: :ok

  defp note!(account, note, user, type) do
    if String.trim(note) != "" do
      now = DateTime.utc_now()

      TenantRepo.insert_all("m_note", [
        %{
          savings_account_id: account.id,
          client_id: account.client_id,
          note_type_enum: type,
          note: note,
          created_by: user.id,
          created_on_utc: now,
          last_modified_by: user.id,
          last_modified_on_utc: now
        }
      ])
    end

    :ok
  end

  defp result(account, changes) do
    client = Clients.fetch!(account.client_id)

    Result.new(
      resource_id: account.id,
      savings_id: account.id,
      office_id: client.office_id,
      client_id: client.id,
      changes: changes
    )
  end
end
