defmodule ECBLoans.Loans.Transitions do
  @moduledoc """
  The steps a loan application goes through before money moves: approve, take the approval back, reject,
  withdraw by the applicant, and delete the application. Follows Fineract's
  `LoanApplicationValidator.validateApproval`, `LoanApplicationTransitionValidator` and
  `LoanApplicationWritePlatformServiceJpaRepositoryImpl`.

  A loan can only be approved, rejected, withdrawn or deleted while it is "submitted and pending approval";
  an approval can only be taken back while it is "approved". Approving for a smaller amount, or for another
  disbursement date, works the repayment schedule out again.
  """
  import Ecto.Query

  alias ECBLoans.{Loans, Schedule}
  alias ECBLoans.Loans.{ChargeRows, Submit}
  alias ECBLoans.Schedule.Request
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @approve_supported ~w(loanIdToBeApproved approvedLoanAmount approvedOnDate netDisbursalAmount note locale
                        dateFormat disbursementData expectedDisbursementDate)
  @reject_supported ~w(rejectedOnDate note locale dateFormat)
  @withdraw_supported ~w(withdrawnOnDate note locale dateFormat)
  @undo_supported ~w(note)

  # --- approve ----------------------------------------------------------------------------------

  @doc "Approves loan `id`, for a smaller amount or another disbursement date when the request says so."
  @spec approve!(struct, integer, Params.t()) :: Result.t()
  def approve!(user, id, %Params{} = p) do
    Params.check_supported!(p, @approve_supported)
    amount = Params.decimal_with_locale(p, "approvedLoanAmount")
    approved_on = Params.date(p, "approvedOnDate")
    expected = Params.date(p, "expectedDisbursementDate")
    note = Params.string(p, "note")

    v =
      Validation.new("loanapplication")
      |> Validation.param("approvedLoanAmount", amount)
      |> Validation.ignore_if_null()
      |> Validation.positive_amount()
      |> then(
        &Validation.param(
          &1,
          "netDisbursalAmount",
          Params.decimal_with_locale(p, "netDisbursalAmount")
        )
      )
      |> Validation.ignore_if_null()
      |> Validation.positive_amount()
      |> then(&Validation.param(&1, "approvedOnDate", approved_on))
      |> Validation.not_null()
      |> then(&Validation.param(&1, "note", note))
      |> Validation.max_length(1000)

    loan = Loans.fetch!(id)
    client = active_client!(loan)
    expected_on = expected || loan.expected_disbursedon_date

    v = approval_checks!(v, loan, client, approved_on, expected_on, amount)
    Validation.raise_if_errors!(v)
    changed_terms_with_tranches!(loan, amount, expected)

    changes = apply_approval(user, loan, approved_on, expected, amount, p)
    Loans.add_note(id, loan.client_id, note, user.id)
    changes = if blank?(note), do: changes, else: Map.put(changes, "note", note)
    result(loan, changes)
  end

  # Approving for another amount or date works a loan paid out in tranches out in ways Fineract itself gets wrong
  # (the tranches no longer fit the amount, the dates fall apart): refused rather than copied
  defp changed_terms_with_tranches!(loan, amount, expected) do
    other_amount? = amount != nil and not Decimal.eq?(amount, loan.principal_amount)
    other_date? = expected != nil and expected != loan.expected_disbursedon_date

    if other_amount? or other_date?,
      do: ECBLoans.Tranches.guard!(loan.id, "approving for another amount or disbursement date")
  end

  # Fineract throws the first of these it meets and collects the others to report together at the end.
  defp approval_checks!(v, loan, client, approved_on, expected_on, amount) do
    check_not_before_submittal!(approved_on, loan)
    pending? = loan.loan_status_id == Loans.status(:submitted)

    v =
      unless_pending(
        v,
        pending?,
        "Loan Account Approval is not allowed. Loan Account is not in submitted and pending approval state."
      )

    check_amount!(amount, loan)
    check_expected_disbursement!(approved_on, expected_on)
    check_not_before_transfer!(approved_on, client)
    check_not_future!(approved_on)
    unless_pending(v, pending?, "Loan is already approved.")
  end

  defp unless_pending(v, true, _message), do: v

  defp unless_pending(v, false, message) do
    Validation.add_error(
      v,
      "error.msg.loan.approve.account.is.not.submitted.and.pending.state",
      message,
      "id",
      []
    )
  end

  defp check_not_before_submittal!(nil, _loan), do: :ok

  defp check_not_before_submittal!(approved_on, loan) do
    if Date.compare(approved_on, loan.submittedon_date) == :lt do
      transition_error!(
        "approval",
        "cannot.be.before.submittal.date",
        "Loan approval date #{approved_on} can not be before its submittal date: #{loan.submittedon_date}",
        [approved_on, loan.submittedon_date]
      )
    end
  end

  defp check_amount!(nil, _loan), do: :ok

  defp check_amount!(amount, loan) do
    if Decimal.compare(amount, loan.principal_amount_proposed) == :gt do
      transition_error!(
        "approval",
        "amount.can't.be.greater.than.loan.amount.demanded",
        "Loan approved amount can't be greater than loan amount demanded.",
        [Decimal.to_float(loan.principal_amount_proposed), amount]
      )
    end
  end

  defp check_expected_disbursement!(approved_on, expected_on)
       when is_nil(approved_on) or is_nil(expected_on),
       do: :ok

  defp check_expected_disbursement!(approved_on, expected_on) do
    if Date.compare(expected_on, approved_on) == :lt do
      transition_error!(
        "expecteddisbursal",
        "should.be.on.or.after.approval.date",
        "The expected disbursement date #{expected_on} should be either on or after the approval date: #{approved_on}",
        [approved_on, expected_on]
      )
    end
  end

  defp check_not_before_transfer!(nil, _client), do: :ok

  defp check_not_before_transfer!(approved_on, %{office_joining_date: joined})
       when not is_nil(joined) do
    if Date.compare(approved_on, joined) == :lt do
      transition_error!(
        "approval",
        "cannot.be.before.client.transfer.date",
        "The date on which a loan is approved cannot be earlier than client's transfer date to this office",
        [joined]
      )
    end
  end

  defp check_not_before_transfer!(_approved_on, _client), do: :ok

  defp check_not_future!(nil), do: :ok

  defp check_not_future!(approved_on) do
    if Date.compare(approved_on, BusinessDate.current()) == :gt do
      transition_error!(
        "approval",
        "cannot.be.a.future.date",
        "The date on which a loan is approved cannot be in the future.",
        [approved_on]
      )
    end
  end

  defp apply_approval(user, loan, approved_on, expected, amount, p) do
    set =
      [
        loan_status_id: Loans.status(:approved),
        approvedon_date: approved_on,
        approvedon_userid: user.id
      ] ++ if(expected, do: [expected_disbursedon_date: expected], else: [])

    set =
      if amount,
        do:
          set ++
            [approved_principal: amount, principal_amount: amount, net_disbursal_amount: amount],
        else:
          set ++
            [
              net_disbursal_amount:
                Decimal.sub(
                  loan.approved_principal,
                  loan.total_charges_due_at_disbursement_derived || 0
                )
            ]

    update!(loan.id, set, user)

    if loan.loan_officer_id do
      officer_history!(loan, approved_on, user)
    end

    if amount || expected, do: regenerate!(loan.id, user)

    %{
      "status" => Loans.status_json(Loans.status(:approved)),
      "locale" => Params.string(p, "locale"),
      "dateFormat" => Params.string(p, "dateFormat"),
      "approvedOnDate" => Params.string(p, "approvedOnDate")
    }
    |> put_if(amount, fn ->
      %{
        "approvedLoanAmount" => amount,
        "principal" => amount,
        "netDisbursalAmount" => loan.net_disbursal_amount
      }
    end)
    |> put_if(expected, fn -> %{"expectedDisbursementDate" => expected} end)
  end

  defp officer_history!(loan, approved_on, user) do
    now = NaiveDateTime.utc_now()

    TenantRepo.insert_all("m_loan_officer_assignment_history", [
      %{
        loan_id: loan.id,
        loan_officer_id: loan.loan_officer_id,
        start_date: approved_on,
        createdby_id: user.id,
        created_date: now,
        lastmodifiedby_id: user.id,
        lastmodified_date: now
      }
    ])
  end

  # --- undo approval ----------------------------------------------------------------------------

  @doc "Takes the approval of loan `id` back: it is pending approval again, for the amount it was asked for."
  @spec undo_approval!(struct, integer, Params.t()) :: Result.t()
  def undo_approval!(user, id, %Params{} = p) do
    Params.check_supported!(p, @undo_supported)
    loan = Loans.fetch!(id)
    active_client!(loan)

    if loan.loan_status_id != Loans.status(:approved) do
      Validation.new("loanapplication")
      |> Validation.add_error(
        "error.msg.loan.undo.approval.account.is.not.approved",
        "Loan Account Undo Approval is not allowed. Loan Account is not in approved state.",
        "id",
        []
      )
      |> Validation.raise_if_errors!()
    end

    changes = %{"status" => Loans.status_json(Loans.status(:submitted))}

    differs? = Decimal.compare(loan.approved_principal, loan.principal_amount_proposed) != :eq

    set = [
      loan_status_id: Loans.status(:submitted),
      approvedon_date: nil,
      approvedon_userid: nil,
      net_disbursal_amount: loan.principal_amount_proposed
    ]

    set =
      if differs?,
        do:
          set ++
            [
              approved_principal: loan.principal_amount_proposed,
              principal_amount: loan.principal_amount_proposed
            ],
        else: set

    update!(id, set, user)
    TenantRepo.delete_all(from(h in "m_loan_officer_assignment_history", where: h.loan_id == ^id))
    if differs?, do: regenerate!(id, user)

    changes =
      if differs?,
        do:
          Map.merge(changes, %{
            "approvedLoanAmount" => loan.principal_amount_proposed,
            "principal" => loan.principal_amount_proposed
          }),
        else: changes

    changes = Map.put(changes, "approvedOnDate", "")
    Loans.add_note(id, loan.client_id, Params.string(p, "note"), user.id)
    result(loan, changes)
  end

  # --- reject and withdraw ----------------------------------------------------------------------

  @doc "Rejects the application for loan `id`."
  @spec reject!(struct, integer, Params.t()) :: Result.t()
  def reject!(user, id, %Params{} = p) do
    close_application!(user, id, p, %{
      supported: @reject_supported,
      param: "rejectedOnDate",
      status: :rejected,
      verb: "reject",
      date_column: :rejectedon_date,
      user_column: :rejectedon_userid,
      not_pending: &reject_not_pending/0
    })
  end

  @doc "The applicant withdraws the application for loan `id`."
  @spec withdraw!(struct, integer, Params.t()) :: Result.t()
  def withdraw!(user, id, %Params{} = p) do
    close_application!(user, id, p, %{
      supported: @withdraw_supported,
      param: "withdrawnOnDate",
      status: :withdrawn,
      verb: "withdraw",
      date_column: :withdrawnon_date,
      user_column: :withdrawnon_userid,
      not_pending: &withdraw_not_pending/0
    })
  end

  defp reject_not_pending do
    Validation.new("loanapplication")
    |> Validation.add_error(
      "error.msg.loan.reject.account.is.not.submitted.pending.approval.state",
      "Loan application cannot be rejected. Loan Account is not in Submitted and Pending approval state.",
      "id",
      []
    )
    |> Validation.raise_if_errors!()
  end

  defp withdraw_not_pending do
    raise DomainRuleViolation,
      code: "error.msg.loan.withdraw.cannot.withdraw",
      message:
        "Only the loan applications with status 'Submitted and pending approval' are allowed to be withdrawn by applicant.",
      args: []
  end

  defp close_application!(user, id, p, spec) do
    Params.check_supported!(p, spec.supported)
    on = Params.date(p, spec.param)
    note = Params.string(p, "note")

    Validation.new("loanapplication")
    |> Validation.param(spec.param, on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    active_client!(loan)

    if loan.loan_status_id != Loans.status(:submitted), do: spec.not_pending.()

    if Date.compare(on, loan.submittedon_date) == :lt do
      transition_error!(
        spec.verb,
        "cannot.be.before.submittal.date",
        "The date on which a loan is #{past(spec.verb)} cannot be before its submittal date: #{loan.submittedon_date}",
        [on, loan.submittedon_date]
      )
    end

    if Date.compare(on, BusinessDate.current()) == :gt do
      transition_error!(
        spec.verb,
        "cannot.be.a.future.date",
        "The date on which a loan is #{past(spec.verb)} cannot be in the future.",
        [on]
      )
    end

    set = [
      {:loan_status_id, Loans.status(spec.status)},
      {spec.date_column, on},
      {spec.user_column, user.id},
      {:closedon_date, on},
      {:closedon_userid, user.id}
    ]

    update!(id, set, user)
    Loans.add_note(id, loan.client_id, note, user.id)
    text = Params.string(p, spec.param)

    changes = %{
      "status" => Loans.status_json(Loans.status(spec.status)),
      "locale" => Params.string(p, "locale"),
      "dateFormat" => Params.string(p, "dateFormat"),
      spec.param => text,
      "closedOnDate" => text
    }

    result(loan, changes)
  end

  defp past("reject"), do: "rejected"
  defp past("withdraw"), do: "withdrawn"

  # --- delete -----------------------------------------------------------------------------------

  @doc "Deletes the application for loan `id`, which must still be pending approval."
  @spec delete!(struct, integer) :: Result.t()
  def delete!(_user, id) do
    loan = Loans.fetch!(id)
    active_client!(loan)

    if loan.loan_status_id != Loans.status(:submitted) do
      raise DomainRuleViolation,
        code: "error.msg.loan.cannot.delete.loan.in.its.present.state",
        message: "Loan with identifier #{id} cannot be deleted in its current state.",
        args: [id]
    end

    TenantRepo.delete_all(from(n in "m_note", where: n.loan_id == ^id))
    TenantRepo.delete_all(from(h in "m_loan_officer_assignment_history", where: h.loan_id == ^id))
    TenantRepo.delete_all(from(r in "m_loan_repayment_schedule", where: r.loan_id == ^id))
    TenantRepo.delete_all(from(l in "m_loan", where: l.id == ^id))
    result(loan, nil)
  end

  # --- the schedule again -----------------------------------------------------------------------

  @doc """
  Works the repayment schedule of loan `id` out again from its stored terms (after approval for another
  amount or date) and replaces the stored rows and the maturity date.
  """
  @spec regenerate!(integer, struct, keyword) :: :ok
  def regenerate!(id, user, opts \\ []) do
    loan = Loans.fetch!(id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    disbursed_on = Keyword.get(opts, :disbursed_on) || loan.expected_disbursedon_date
    charges = Keyword.get(opts, :charges) || ChargeRows.params(id)
    terms = stored_terms(loan, product, disbursed_on, charges)
    schedule = Schedule.generate(terms)
    last = List.last(schedule.periods)

    ChargeRows.clear_installment_charges!(id)
    clear_repayment_mappings!(id)
    TenantRepo.delete_all(from(r in "m_loan_repayment_schedule", where: r.loan_id == ^id))
    Submit.insert_installments!(id, schedule, user, DateTime.utc_now())

    ChargeRows.store!(id, schedule, user,
      replace: Keyword.has_key?(opts, :charges) and not Keyword.get(opts, :append, false),
      append: Keyword.get(opts, :append, false)
    )

    update!(id, [expected_maturedon_date: last.due, maturedon_date: last.due], user)
  end

  # what each repayment paid of each installment is worked out again once the new schedule stands
  defp clear_repayment_mappings!(id) do
    tx_ids = from(t in "m_loan_transaction", where: t.loan_id == ^id, select: t.id)

    TenantRepo.delete_all(
      from(m in "m_loan_transaction_repayment_schedule_mapping",
        where: m.loan_transaction_id in subquery(tx_ids)
      )
    )
  end

  @doc "The terms the loan's schedule is worked out from, as the loan stores them."
  @spec stored_terms(map, map, Date.t(), [map]) :: map
  def stored_terms(loan, product, disbursed_on, charges),
    do: Request.terms(loan_params(loan, disbursed_on, charges), product)

  # the loan's stored terms, said the way a request would say them
  defp loan_params(loan, disbursed_on, charges) do
    number = fn d -> Jason.Fragment.new(Decimal.to_string(d, :normal)) end
    date = &Date.to_iso8601/1

    %{
      "principal" => number.(loan.principal_amount),
      "amortizationType" => loan.amortization_method_enum,
      "interestType" => loan.interest_method_enum,
      "interestCalculationPeriodType" => loan.interest_calculated_in_period_enum,
      "allowPartialPeriodInterestCalculation" => loan.allow_partial_period_interest_calcualtion,
      "loanTermFrequency" => loan.term_frequency,
      "numberOfRepayments" => loan.number_of_repayments,
      "repaymentEvery" => loan.repay_every,
      "repaymentFrequencyType" => loan.repayment_period_frequency_enum,
      "interestRatePerPeriod" => number.(loan.nominal_interest_rate_per_period),
      "interestRateFrequencyType" => loan.interest_period_frequency_enum,
      "daysInYearType" => loan.days_in_year_enum,
      "expectedDisbursementDate" => date.(disbursed_on),
      "submittedOnDate" => date.(loan.submittedon_date),
      "dateFormat" => "yyyy-MM-dd",
      "locale" => "en",
      "charges" => charges
    }
    |> put_some("disbursementData", tranche_params(loan))
    |> put_some(
      "maxOutstandingLoanBalance",
      loan.max_outstanding_loan_balance && number.(loan.max_outstanding_loan_balance)
    )
    |> put_some("graceOnPrincipalPayment", loan.grace_on_principal_periods)
    |> put_some("graceOnInterestPayment", loan.grace_on_interest_periods)
    |> put_some("graceOnInterestCharged", loan.grace_interest_free_periods)
    |> put_some(
      "repaymentsStartingFromDate",
      loan.expected_firstrepaymenton_date && date.(loan.expected_firstrepaymenton_date)
    )
    |> Jason.encode!()
    |> Params.parse!()
  end

  # the tranches the loan has, on the day each was paid out or is expected
  defp tranche_params(loan) do
    case ECBLoans.Tranches.list(loan.id) do
      [] ->
        nil

      tranches ->
        for t <- tranches do
          %{
            "expectedDisbursementDate" => Date.to_iso8601(t.disbursed_on || t.expected_date),
            "principal" => Jason.Fragment.new(Decimal.to_string(t.principal, :normal))
          }
        end
    end
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # --- shared -----------------------------------------------------------------------------------

  defp active_client!(loan) do
    client = Clients.fetch!(loan.client_id)

    if client.status_enum != Clients.status(:active) do
      raise ECBPlatform.Errors.DomainRuleViolation,
        code: "error.msg.client.not.active.exception",
        message: "The Client with id `#{client.id}` is not active",
        args: [client.id]
    end

    Map.put(
      client,
      :office_joining_date,
      TenantRepo.one(
        from(c in "m_client", where: c.id == ^client.id, select: c.office_joining_date)
      )
    )
  end

  defp update!(id, set, user) do
    set = set ++ [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]
    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id), set: set)
    :ok
  end

  defp transition_error!(step, code, message, args) do
    raise DomainRuleViolation,
      code: "error.msg.loan.#{step}.#{code}",
      message: message,
      args: Enum.map(args, &arg/1)
  end

  defp arg(%Date{} = date), do: Date.to_iso8601(date)
  defp arg(other), do: other

  defp result(loan, changes) do
    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: loan.id,
      resource_id: loan.id,
      resource_external_id: loan.external_id,
      changes: changes
    )
  end

  defp put_if(map, nil, _fun), do: map
  defp put_if(map, _value, fun), do: Map.merge(map, fun.())

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""
end
