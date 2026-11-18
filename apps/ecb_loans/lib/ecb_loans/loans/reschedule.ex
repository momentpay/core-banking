defmodule ECBLoans.Loans.Reschedule do
  @moduledoc """
  Approving a request to reschedule a loan (`RescheduleRequests`), after Fineract's
  `LoanRescheduleRequestWritePlatformServiceImpl.approve`.

  The installments that fall due before the request's date stay as they are. The rest of the schedule is made again
  with the term variations of the request (and the rate, graces and extra installments they ask for), as
  `AbstractCumulativeLoanScheduleGenerator.rescheduleNextInstallments` does, and replaces the old installments, which
  are kept as history (`m_loan_repayment_schedule_history`). The repayments the loan has had are worked out again on
  the new schedule, and the interest accrued at disbursement, where the loan does that, is booked again.
  """
  import Ecto.Query

  alias ECBLoans.{LoanProducts, Loans, RescheduleRequests, Schedule}
  alias ECBLoans.Loans.{Foreclosure, Reprocess, Submit, Transitions}
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result

  @doc "Approves request `id` as of `approvedOnDate`."
  @spec approve!(struct, integer, Params.t()) :: Result.t()
  def approve!(user, id, %Params{} = p) do
    request = RescheduleRequests.fetch!(id)
    Params.check_supported!(p, RescheduleRequests.approve_params())
    on = Params.date(p, "approvedOnDate")
    loan = Loans.fetch!(request.loan_id)
    installments = Loans.installments(loan.id)
    installment = Enum.find(installments, &(&1.due_date == request.reschedule_from_date))

    check!(request, loan, installment, on)
    RescheduleRequests.refuse_loan_unsupported!(loan)

    product = LoanProducts.fetch!(loan.product_id)
    {kept, schedule} = compute(id, loan, installments, request.reschedule_from_date, product)

    now = DateTime.utc_now()
    archive!(user, loan, installments, id, now)
    replace_installments!(user, loan, kept, schedule, now)

    last = List.last(schedule.periods)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan.id),
      set: [
        expected_maturedon_date: last.due,
        maturedon_date: last.due,
        rescheduledon_date: BusinessDate.current(),
        rescheduledon_userid: user.id,
        last_modified_by: user.id,
        last_modified_on_utc: now
      ]
    )

    Reprocess.run!(user, loan.id)
    Foreclosure.make_accruals_again!(user, Loans.fetch!(loan.id), product)

    ids = for t <- RescheduleRequests.variations(id), do: t.id

    TenantRepo.update_all(from(t in "m_loan_term_variations", where: t.id in ^ids),
      set: [is_active: true, last_modified_by: user.id, last_modified_on_utc: now]
    )

    TenantRepo.update_all(from(r in "m_loan_reschedule_request", where: r.id == ^id),
      set: [
        status_enum: RescheduleRequests.status(:approved),
        approved_on_date: on,
        approved_by_user_id: user.id
      ]
    )

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: loan.id,
      resource_id: id,
      changes: %{
        "locale" => Params.locale(p),
        "dateFormat" => Params.date_format(p),
        "approvedOnDate" => Params.string(p, "approvedOnDate"),
        "approvedByUserId" => user.id
      }
    )
  end

  # `LoanRescheduleRequestDataValidatorImpl.validateForApproveAction`
  defp check!(request, loan, installment, on) do
    resource = RescheduleRequests.resource()

    v =
      resource
      |> Validation.new()
      |> Validation.param("approvedOnDate", on)
      |> Validation.not_null()

    v =
      if on && Date.compare(request.submitted_on_date, on) == :gt,
        do:
          Validation.add_error(
            v,
            "validation.msg.#{resource}.approvedOnDate.before.submission.date",
            "Failed data validation due to: before.submission.date.",
            "approvedOnDate",
            [nil, ["Approval date cannot be before the request submission date."]]
          ),
        else: v

    v
    |> RescheduleRequests.pending(
      request,
      "Loan reschedule request approval is not allowed. Loan reschedule request is not in submitted and pending approval state."
    )
    |> RescheduleRequests.check_active_loan(loan)
    |> RescheduleRequests.check_installment_of(loan, installment)
    |> Validation.raise_if_errors!()
  end

  @doc """
  The schedule request `id` would make (`previewLoanReschedule`): `{loan, schedule}`. Fineract adds what the request
  asks for to the variations the loan has already, so the preview of a request that was approved already shows its
  changes twice.
  """
  @spec preview!(integer) :: {map, map}
  def preview!(id) do
    request = RescheduleRequests.fetch!(id)
    loan = Loans.fetch!(request.loan_id)
    RescheduleRequests.refuse_loan_unsupported!(loan, :preview)
    product = LoanProducts.fetch!(loan.product_id)
    installments = Loans.installments(loan.id)

    {kept, schedule} =
      compute(id, loan, installments, request.reschedule_from_date, product, active: true)

    if kept > 0 and RescheduleRequests.active_variations?(loan.id),
      do: RescheduleRequests.unsupported!("Previewing a request for a loan that was rescheduled")

    {loan, schedule}
  end

  defp compute(id, loan, installments, from, product, opts \\ []) do
    terms = Transitions.stored_terms(loan, product, loan.disbursedon_date, [])

    active =
      if opts[:active],
        do: for(v <- RescheduleRequests.active_variations(loan.id), do: %{v | id: {:loan, v.id}}),
        else: []

    variations =
      for v <- RescheduleRequests.variations(id), do: %{v | id: {:request, v.id}}

    variations =
      (active ++ variations)
      |> Enum.map(&Map.take(&1, [:id, :type, :from, :decimal, :date, :specific?]))

    reschedule(loan, terms, installments, from, variations)
  end

  # --- the new schedule ---------------------------------------------------------------------------

  # `{how many installments stay, the schedule}`
  defp reschedule(loan, terms, installments, from, variations) do
    kept = retained(installments, from)
    interest = Enum.reduce(kept, Decimal.new(0), &Decimal.add(&2, &1.interest || Decimal.new(0)))

    if kept != [] and Decimal.gt?(interest, 0) do
      periods = periods(kept, terms)
      total = ECBMoney.new(terms.currency, loan.interest_charged_derived, terms.context)

      schedule =
        Schedule.generate(terms,
          variations: variations,
          resume: %{periods: periods, total_interest_due: total}
        )

      {length(kept), schedule}
    else
      {0, Schedule.generate(terms, variations: variations)}
    end
  end

  # the installments due before the date, without a tail that carries no interest
  # (`fetchRetainedInstallments`)
  defp retained(installments, from) do
    kept = Enum.take_while(installments, &(Date.compare(&1.due_date, from) == :lt))

    last_with_interest =
      kept
      |> Enum.filter(&(&1.interest != nil and Decimal.gt?(&1.interest, 0)))
      |> Enum.map(& &1.installment)
      |> Enum.max(fn -> 0 end)

    case List.last(kept) do
      %{installment: number} when number != last_with_interest ->
        Enum.filter(kept, &(&1.installment <= last_with_interest))

      _ ->
        kept
    end
  end

  # the installments that stay, each with what is still to be repaid after it
  defp periods(kept, terms) do
    {periods, _balance} =
      Enum.map_reduce(kept, terms.principal, fn row, balance ->
        period = period(row, terms)
        left = ECBMoney.minus(balance, period.principal)
        {%{period | balance: left}, left}
      end)

    periods
  end

  defp period(row, terms) do
    money = fn amount -> ECBMoney.new(terms.currency, amount || Decimal.new(0), terms.context) end
    principal = money.(row.principal)
    interest = money.(row.interest)
    fees = money.(row.fee_charges)
    penalties = money.(row.penalty_charges)

    %{
      number: row.installment,
      from: row.from_date,
      due: row.due_date,
      principal: principal,
      balance: principal,
      interest: interest,
      fees: fees,
      penalties: penalties,
      total:
        principal |> ECBMoney.plus(interest) |> ECBMoney.plus(fees) |> ECBMoney.plus(penalties)
    }
  end

  # --- what is written ------------------------------------------------------------------------------

  # the schedule as it was, kept with the request (`createLoanScheduleArchive`)
  defp archive!(user, loan, installments, request_id, now) do
    rows =
      for i <- installments do
        %{
          loan_id: loan.id,
          loan_reschedule_request_id: request_id,
          fromdate: i.from_date,
          duedate: i.due_date,
          installment: i.installment,
          principal_amount: i.principal,
          interest_amount: i.interest,
          fee_charges_amount: i.fee_charges,
          penalty_charges_amount: i.penalty_charges,
          createdby_id: user.id,
          lastmodifiedby_id: user.id,
          created_date: DateTime.to_naive(now),
          lastmodified_date: DateTime.to_naive(now),
          version: 1,
          created_on_utc: now,
          last_modified_on_utc: now
        }
      end

    TenantRepo.insert_all("m_loan_repayment_schedule_history", rows)
  end

  defp replace_installments!(user, loan, kept, schedule, now) do
    tx_ids =
      TenantRepo.all(from(t in "m_loan_transaction", where: t.loan_id == ^loan.id, select: t.id))

    TenantRepo.delete_all(
      from(m in "m_loan_transaction_repayment_schedule_mapping",
        where: m.loan_transaction_id in ^tx_ids
      )
    )

    TenantRepo.delete_all(
      from(r in "m_loan_repayment_schedule",
        where: r.loan_id == ^loan.id and r.installment > ^kept
      )
    )

    new = %{schedule | periods: Enum.filter(schedule.periods, &(&1.number > kept))}
    Submit.insert_installments!(loan.id, new, user, now)
  end
end
