defmodule ECBLoans.Loans.Officers do
  @moduledoc """
  Giving a loan to another loan officer and taking it from one, following Fineract's
  `LoanWritePlatformServiceJpaRepositoryImpl.loanReassignment` / `removeLoanOfficer`, `LoanOfficerService` and
  `LoanOfficerValidator`.

  Once a loan is approved every officer it has had is kept in `m_loan_officer_assignment_history` with the day the
  assignment began and the day it ended. Giving the loan to the officer it already has moves the day it began;
  giving it to another on the day the assignment began replaces the officer; otherwise the current assignment ends
  on the new day and a new one begins. A loan still waiting for approval keeps no history.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Repay, Submit}
  alias ECBPlatform.{BusinessDate, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @reassign_supported ~w(assignmentDate fromLoanOfficerId toLoanOfficerId locale dateFormat)
  @unassign_supported ~w(unassignedDate locale dateFormat)

  # --- assign ------------------------------------------------------------------------------------

  @doc "Gives loan `id` to loan officer `toLoanOfficerId` from `assignmentDate`; `fromLoanOfficerId` must be its present one."
  @spec reassign!(struct, integer, Params.t()) :: Result.t()
  def reassign!(user, id, %Params{} = p) do
    Params.check_supported!(p, @reassign_supported)
    to_id = Json.long(p, "toLoanOfficerId")

    Validation.new("loanOfficer")
    |> Validation.param("toLoanOfficerId", to_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("assignmentDate", Params.string(p, "assignmentDate"))
    |> Validation.not_blank()
    |> Validation.raise_if_errors!()

    on = Params.date(p, "assignmentDate")
    from_id = Json.long(p, "fromLoanOfficerId")
    from = Submit.officer!(from_id)
    to = Submit.officer!(to_id)

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    check_holds!(loan, from, from_id)

    history = history(id)
    latest = Enum.find(history, &(&1.end_date == nil))
    check_assignment_date!(loan, on, last_assignment(history, to.id))
    check_not_before_latest!(loan, latest, on)
    assign!(user, loan, to, latest, on)

    done(loan)
  end

  # the loan must have the officer the request says it has (Fineract fails with a 500 when none is named)
  defp check_holds!(%{loan_officer_id: nil}, _from, nil), do: :ok

  defp check_holds!(%{loan_officer_id: officer}, %{id: officer}, _from_id), do: :ok

  defp check_holds!(%{loan_officer_id: nil} = loan, _from, from_id),
    do: not_assigned!(loan, from_id)

  defp check_holds!(loan, nil, _from_id) do
    raise DomainRuleViolation,
      code: "error.msg.loan.not.assigned.to.loan.officer",
      message: "Loan with identifier #{loan.id} has an officer and the request names none",
      args: [loan.id]
  end

  defp check_holds!(loan, _from, from_id), do: not_assigned!(loan, from_id)

  defp not_assigned!(loan, from_id) do
    raise DomainRuleViolation,
      code: "error.msg.loan.not.assigned.to.loan.officer",
      message:
        "Loan with identifier #{loan.id} is not assigned to Loan Officer with identifier #{from_id}.",
      args: [loan.id]
  end

  # the record that ended last among those of other officers, or the current one if it is of another officer
  defp last_assignment(history, new_id) do
    Enum.reduce_while(history, nil, fn record, last ->
      cond do
        record.end_date == nil and record.loan_officer_id != new_id -> {:halt, record}
        last == nil -> {:cont, record}
        later_end?(record, last) and record.loan_officer_id != new_id -> {:cont, record}
        true -> {:cont, last}
      end
    end)
  end

  defp later_end?(%{end_date: nil}, _last), do: false
  defp later_end?(%{end_date: end_date}, %{end_date: nil}), do: end_date != nil

  defp later_end?(%{end_date: end_date}, %{end_date: other}),
    do: Date.compare(end_date, other) == :gt

  defp check_assignment_date!(loan, on, last) do
    if Date.compare(loan.submittedon_date, on) == :gt do
      date_error!(
        "cannot.be.before.loan.submittal.date",
        "The Loan Officer assignment date (#{on}) cannot be before loan submitted date (#{loan.submittedon_date}).",
        [Date.to_iso8601(on), Date.to_iso8601(loan.submittedon_date)]
      )
    end

    if last && last.end_date && Date.compare(last.end_date, on) == :gt do
      date_error!(
        "cannot.be.before.previous.unassignement.date",
        "The Loan Officer assignment date (#{on}) cannot be before previous Loan Officer unassigned date (#{last.end_date}).",
        [Date.to_iso8601(on), Date.to_iso8601(last.end_date)]
      )
    end

    if Date.compare(on, BusinessDate.current()) == :gt do
      date_error!(
        "cannot.be.a.future.date",
        "The Loan Officer assignment date (#{on}) cannot be in the future.",
        [Date.to_iso8601(on)]
      )
    end
  end

  defp check_not_before_latest!(loan, latest, on) do
    if latest && Date.compare(on, latest.start_date) == :lt do
      date_error!(
        "is.before.last.assignment.date",
        "Loan with identifier #{loan.id} was already assigned before date #{on}",
        [loan.id, Date.to_iso8601(on)]
      )
    end
  end

  defp date_error!(postfix, message, args) do
    raise DomainRuleViolation,
      code: "error.msg.loan.assignment.date." <> postfix,
      message: message,
      args: args
  end

  defp assign!(user, loan, to, latest, on) do
    cond do
      latest && loan.loan_officer_id == to.id ->
        update_history!(user, latest.id, start_date: on)

      latest && Date.compare(latest.start_date, on) == :eq ->
        update_history!(user, latest.id, loan_officer_id: to.id)
        set_officer!(user, loan.id, to.id)

      true ->
        if latest, do: update_history!(user, latest.id, end_date: on)
        set_officer!(user, loan.id, to.id)

        if loan.loan_status_id != Loans.status(:submitted),
          do: insert_history!(user, loan.id, to.id, on)
    end
  end

  # --- unassign ----------------------------------------------------------------------------------

  @doc "Takes loan `id` from its loan officer as of `unassignedDate`."
  @spec unassign!(struct, integer, Params.t()) :: Result.t()
  def unassign!(user, id, %Params{} = p) do
    Params.check_supported!(p, @unassign_supported)

    Validation.new("loan.transaction")
    |> Validation.param("unassignedDate", Params.string(p, "unassignedDate"))
    |> Validation.not_blank()
    |> Validation.raise_if_errors!()

    on = Params.date(p, "unassignedDate")
    loan = Loans.fetch!(id)
    Repay.active_client!(loan)

    if loan.loan_officer_id == nil do
      raise DomainRuleViolation,
        code: "error.msg.loan.not.assigned.to.loan.officer",
        message: "Loan with identifier #{id} is not assigned to any loan officer.",
        args: [id]
    end

    latest = id |> history() |> Enum.find(&(&1.end_date == nil))
    check_unassign_date!(loan, latest, on)
    if latest, do: update_history!(user, latest.id, end_date: on)
    set_officer!(user, id, nil)

    done(loan)
  end

  defp check_unassign_date!(_loan, nil, _on), do: :ok

  defp check_unassign_date!(loan, latest, on) do
    cond do
      Date.compare(latest.start_date, on) == :gt ->
        unassign_error!(
          "cannot.be.before.assignment.date",
          "The Loan officer Unassign date(#{on}) cannot be before its assignment date (#{latest.start_date}).",
          [loan.id, loan.loan_officer_id, Date.to_iso8601(latest.start_date), Date.to_iso8601(on)]
        )

      Date.compare(on, BusinessDate.current()) == :gt ->
        unassign_error!(
          "cannot.be.a.future.date",
          "The Loan Officer Unassign date (#{on}) cannot be in the future.",
          [Date.to_iso8601(on)]
        )

      true ->
        :ok
    end
  end

  defp unassign_error!(postfix, message, args) do
    raise DomainRuleViolation,
      code: "error.msg.loan.loanofficer.unassign.date." <> postfix,
      message: message,
      args: args
  end

  # --- the history and the loan ---------------------------------------------------------------

  defp history(loan_id) do
    TenantRepo.all(
      from(h in "m_loan_officer_assignment_history",
        where: h.loan_id == ^loan_id,
        order_by: h.id,
        select: %{
          id: h.id,
          loan_officer_id: h.loan_officer_id,
          start_date: h.start_date,
          end_date: h.end_date
        }
      )
    )
  end

  defp update_history!(user, id, set) do
    TenantRepo.update_all(from(h in "m_loan_officer_assignment_history", where: h.id == ^id),
      set: set ++ [lastmodifiedby_id: user.id, lastmodified_date: NaiveDateTime.utc_now()]
    )
  end

  defp insert_history!(user, loan_id, officer_id, on) do
    now = NaiveDateTime.utc_now()

    TenantRepo.insert_all("m_loan_officer_assignment_history", [
      %{
        loan_id: loan_id,
        loan_officer_id: officer_id,
        start_date: on,
        createdby_id: user.id,
        created_date: now,
        lastmodifiedby_id: user.id,
        lastmodified_date: now
      }
    ])
  end

  defp set_officer!(user, loan_id, officer_id) do
    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan_id),
      set: [
        loan_officer_id: officer_id,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )
  end

  defp done(loan) do
    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: loan.id,
      resource_id: loan.id,
      resource_external_id: loan.external_id
    )
  end
end
