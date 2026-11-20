defmodule ECBDeposits.Savings.Officers do
  @moduledoc """
  The savings officer of an account: assigning another and taking the officer away, after Fineract's
  `assignFieldOfficer` and `unassignFieldOfficer` and `SavingsAccount.reassignSavingsOfficer` and
  `removeSavingsOfficer`. An account keeps a history of its officers (`m_savings_officer_assignment_history`) from
  the day it is approved. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings
  alias ECBOrg.Offices
  alias ECBParty.Lookups
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ServerError}

  @pending 100

  # --- assigning --------------------------------------------------------------------------------------

  @doc "Gives the account another officer, or its first."
  @spec assign!(struct, integer, Params.t()) :: Result.t()
  def assign!(user, id, %Params{} = p) do
    Params.check_supported!(
      p,
      ~w(fromSavingsOfficerId toSavingsOfficerId assignmentDate locale dateFormat)
    )

    from_id = Params.long(p, "fromSavingsOfficerId")
    to_id = Params.long(p, "toSavingsOfficerId")
    text = Params.string(p, "assignmentDate")
    date = if text not in [nil, ""], do: Params.date(p, "assignmentDate")

    Validation.new("savingsaccount")
    |> Validation.param("toSavingsOfficerId", to_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("assignmentDate", text)
    |> Validation.not_blank()
    |> date_given(text, "assignmentDate", date)
    |> Validation.raise_if_errors!()

    account = Savings.fetch!(id)
    hierarchy = hierarchy(account)
    from = from_id && Lookups.staff!(from_id, hierarchy)
    to = Lookups.staff!(to_id, hierarchy)
    unless holds?(account, from), do: not_assigned!(id, from_id)

    reassign!(user, account, to, date)

    Result.new(
      resource_id: id,
      savings_id: id,
      office_id: account.client_office_id,
      changes: %{"toSavingsOfficerId" => to.id}
    )
  end

  defp date_given(v, text, name, date) do
    if text in [nil, ""],
      do: v,
      else: v |> Validation.param(name, date) |> Validation.not_null()
  end

  # the officer the request names as the one now is the one the account has; an account with an officer asked
  # without one fails in Fineract with an unhandled error
  defp holds?(%{field_officer_id: nil}, from), do: from == nil
  defp holds?(_account, nil), do: raise(ServerError)
  defp holds?(account, from), do: account.field_officer_id == from.id

  defp not_assigned!(id, from_id) do
    raise DomainRuleViolation,
      code: "error.msg.savings.account.not.assigned.to.savings.officer",
      message:
        "Savings Account Identifier #{id} is not assigned to Savings Officer with identifier #{from_id}.",
      args: [id]
  end

  defp hierarchy(account) do
    case Offices.get(account.client_office_id) do
      {:ok, office} -> office.hierarchy
      _ -> "."
    end
  end

  defp history(account_id) do
    from(h in "m_savings_officer_assignment_history",
      where: h.account_id == ^account_id,
      order_by: h.id,
      select: %{id: h.id, officer_id: h.savings_officer_id, start: h.start_date, end: h.end_date}
    )
    |> TenantRepo.all()
  end

  # `SavingsAccount.reassignSavingsOfficer`
  defp reassign!(user, account, to, date) do
    records = history(account.id)
    latest = Enum.find(records, &(&1.end == nil))
    last = last_record(records, to)

    cond do
      Date.compare(date, account.submittedon_date) == :lt ->
        refuse_date!(
          "cannot.be.before.savings.submitted.date",
          "The Savings Officer assignment date (#{date}) cannot be before savings submitted date (#{account.submittedon_date}).",
          [Date.to_iso8601(date), Date.to_iso8601(account.submittedon_date)]
        )

      last != nil and last.end != nil and Date.compare(date, last.end) == :lt ->
        refuse_date!(
          "cannot.be.before.previous.unassignement.date",
          "The Savings Officer assignment date (#{date}) cannot be before previous Savings Officer unassigned date (#{last.end}).",
          [Date.to_iso8601(date), Date.to_iso8601(last.end)]
        )

      Date.compare(date, BusinessDate.current()) == :gt ->
        refuse_date!(
          "cannot.be.a.future.date",
          "The Savings Officer assignment date (#{date}) cannot be in the future.",
          [Date.to_iso8601(date)]
        )

      true ->
        change_officer!(user, account, to, date, latest)
    end
  end

  # with no officer yet a new history starts; else the current record is changed or closed as the dates say
  defp change_officer!(user, account, to, date, nil),
    do: start_officer!(user, account, to, date, nil)

  defp change_officer!(user, account, to, date, latest) do
    cond do
      account.field_officer_id == to.id ->
        update_history!(user, latest.id, start_date: date)

      latest.start == date ->
        update_history!(user, latest.id, savings_officer_id: to.id)
        set_officer!(user, account.id, to.id)

      Date.compare(date, latest.start) == :lt ->
        refuse_date!(
          "is.before.last.assignment.date",
          "Savings account with identifier #{account.id} was already assigned before date #{date}",
          [account.id, Date.to_iso8601(date)]
        )

      true ->
        start_officer!(user, account, to, date, latest)
    end
  end

  defp start_officer!(user, account, to, date, latest) do
    if latest, do: update_history!(user, latest.id, end_date: date)
    set_officer!(user, account.id, to.id)
    if account.status_enum != @pending, do: add_history!(user, account.id, to.id, date)
  end

  # the record of the officers with no end that is another officer's, else the one that ended last
  defp last_record(records, to) do
    Enum.reduce_while(records, nil, fn record, last ->
      cond do
        record.end == nil and record.officer_id != to.id -> {:halt, record}
        last == nil -> {:cont, record}
        later_end?(record, last) and record.officer_id != to.id -> {:cont, record}
        true -> {:cont, last}
      end
    end)
  end

  defp later_end?(%{end: nil}, _last), do: false
  defp later_end?(_record, %{end: nil}), do: false
  defp later_end?(record, last), do: Date.compare(record.end, last.end) == :lt

  # --- unassigning ------------------------------------------------------------------------------------

  @doc "Takes the savings officer of the account away."
  @spec unassign!(struct, integer, Params.t()) :: Result.t()
  def unassign!(user, id, %Params{} = p) do
    Params.check_supported!(p, ~w(unassignedDate locale dateFormat))
    text = Params.string(p, "unassignedDate")
    date = if text not in [nil, ""], do: Params.date(p, "unassignedDate")

    Validation.new("savingsaccount")
    |> Validation.param("unassignedDate", text)
    |> Validation.not_blank()
    |> date_given(text, "unassignedDate", date)
    |> Validation.raise_if_errors!()

    account = Savings.fetch!(id)

    if account.field_officer_id == nil do
      raise DomainRuleViolation,
        code: "error.msg.savings.account.not.assigned.to.savings.officer",
        message: "Savings Account Identifier#{id} is not assigned to any savings officer.",
        args: []
    end

    case Enum.find(history(id), &(&1.end == nil)) do
      nil ->
        :ok

      latest ->
        check_unassign_date!(account, latest, date)
        update_history!(user, latest.id, end_date: date)
    end

    set_officer!(user, id, nil)
    Result.new(resource_id: id, savings_id: id, office_id: account.client_office_id, changes: %{})
  end

  defp check_unassign_date!(account, latest, date) do
    cond do
      Date.compare(date, latest.start) == :lt ->
        raise DomainRuleViolation,
          code: "error.msg.savings.savingsofficer.unassign.date.cannot.be.before.assignment.date",
          message:
            "The Savings officer Unassign date(#{date}) cannot be before its assignment date (#{latest.start}).",
          args: [
            account.id,
            account.field_officer_id,
            Date.to_iso8601(latest.start),
            Date.to_iso8601(date)
          ]

      Date.compare(date, BusinessDate.current()) == :gt ->
        raise DomainRuleViolation,
          code: "error.msg.savings.savingsofficer.unassign.date.cannot.be.a.future.date",
          message: "The Savings Officer Unassign date (#{date}) cannot be in the future.",
          args: [Date.to_iso8601(date)]

      true ->
        :ok
    end
  end

  # --- the rows ---------------------------------------------------------------------------------------

  defp refuse_date!(code, message, args) do
    raise DomainRuleViolation,
      code: "error.msg.savings.assignment.date." <> code,
      message: message,
      args: args
  end

  defp set_officer!(user, id, officer_id) do
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [
        field_officer_id: officer_id,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )
  end

  defp update_history!(user, id, set) do
    TenantRepo.update_all(from(h in "m_savings_officer_assignment_history", where: h.id == ^id),
      set: set ++ [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]
    )
  end

  @doc "Starts the history of an officer of an account on a date."
  @spec add_history!(struct, integer, integer, Date.t()) :: :ok
  def add_history!(user, account_id, officer_id, date) do
    now = DateTime.utc_now()

    TenantRepo.insert_all("m_savings_officer_assignment_history", [
      %{
        account_id: account_id,
        savings_officer_id: officer_id,
        start_date: date,
        created_by: user.id,
        last_modified_by: user.id,
        created_on_utc: now,
        last_modified_on_utc: now
      }
    ])

    :ok
  end
end
