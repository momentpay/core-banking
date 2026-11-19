defmodule ECBLoans.Loans.TrancheEdits do
  @moduledoc """
  Changing the tranches of a loan (`/loans/{id}/disbursements`), following Fineract's
  `addAndDeleteLoanDisburseDetails` (all of them at once: the tranches named with their id are changed, those
  without are added, those left out are removed) and `updateDisbursementDateAndAmountForTranche` (the date and
  amount of one).

  Fineract changes only the tranches of a loan that is not paid out and leaves its schedule as it is (the schedule
  is worked out again when a tranche is paid out). On a loan that has been paid out it makes the loan's principal
  the sum of what was paid and the loan's totals no longer agree with its schedule; that is not copied: such a
  change is refused with `error.msg.loan.feature.not.supported.yet`, as is what Fineract answers with a database
  error, and tranches that add up to more than the loan.
  """
  alias ECBLoans.{LoanProducts, Loans, Tranches}
  alias ECBLoans.Loans.Repay
  alias ECBLoans.Schedule.TrancheInput
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ServerError}
  alias ECBPlatform.{Params, Validation}

  # submitted, withdrawn, rejected, closed (three ways) and overpaid: the tranches may not be edited all at once
  @not_editable [100, 400, 500, 600, 601, 602, 700]
  # withdrawn, rejected and closed
  @closed [400, 500, 600, 601, 602]
  @approved 200
  @one_supported ~w(locale dateFormat disbursementData approvedLoanAmount updatedExpectedDisbursementDate
                    updatedPrincipal expectedDisbursementDate)

  @doc "Adds, changes and removes the tranches of loan `id` as the request lists them."
  @spec update_all!(struct, integer, Params.t()) :: Result.t()
  def update_all!(_user, id, %Params{} = p) do
    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    check_charged_off!(loan)
    product = LoanProducts.fetch!(loan.product_id)
    check_multi!(product)

    if loan.loan_status_id in @not_editable do
      refuse!(
        "error.msg.cannot.modify.tranches.if.loan.is.pendingapproval.closed.overpaid.writtenoff",
        "cannot.modify.tranches.if.loan.is.pendingapproval.closed.overpaid.writtenoff"
      )
    end

    TrancheInput.required!(p, product)

    "loan"
    |> Validation.new()
    |> TrancheInput.validate(
      p,
      loan.expected_disbursedon_date,
      Params.decimal_with_locale(p, "approvedLoanAmount")
    )
    |> Validation.raise_if_errors!()

    check_not_all_paid!(loan)

    entries = TrancheInput.entries(p)
    TrancheInput.max!(length(entries), product)

    if not product.disallow_expected_disbursements, do: apply_all!(loan, entries)

    result(loan, nil)
  end

  defp check_multi!(product) do
    if not TrancheInput.multi?(product) do
      refuse!(
        "error.msg.loan.product.does.not.support.multiple.disbursals",
        "loan.product.does.not.support.multiple.disbursals"
      )
    end
  end

  defp check_charged_off!(%{is_charged_off: true} = loan) do
    raise DomainRuleViolation,
      code: "error.msg.loan.is.charged.off",
      message:
        "Update Loan: #{loan.id} disbursement details is not allowed. Loan Account is Charged-off",
      args: [loan.id]
  end

  defp check_charged_off!(_loan), do: :ok

  # a loan that has been paid out in full cannot have its tranches changed
  defp check_not_all_paid!(loan) do
    paid =
      loan.id
      |> Tranches.list()
      |> Enum.reject(&is_nil(&1.disbursed_on))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.principal))

    if Decimal.eq?(paid, loan.approved_principal) do
      refuse!(
        "error.msg.loan.disbursement.cannot.be.a.edited",
        "loan.disbursement.cannot.be.a.edited"
      )
    end
  end

  defp apply_all!(loan, entries) do
    standing = Tranches.list(loan.id)
    known = Map.new(standing, &{&1.id, &1})

    Enum.each(entries, &check_entry!(&1, known))
    check_total!(loan, entries)

    if loan.loan_status_id != @approved,
      do: Tranches.unsupported!("changing the tranches of a loan that is paid out")

    kept = for %{id: id} <- entries, id != nil, do: id
    Tranches.delete!(for t <- standing, t.id not in kept, do: t.id)
    Enum.each(entries, &store_entry!(loan, &1, known))
  end

  defp check_entry!(entry, known) do
    if entry.principal == nil, do: raise(ServerError)
    if entry.date == nil, do: Tranches.unsupported!("a tranche without its date")
    if entry.id != nil and not is_map_key(known, entry.id), do: raise(ServerError)
  end

  defp check_total!(loan, entries) do
    total = entries |> Enum.map(& &1.principal) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    if Decimal.gt?(total, loan.approved_principal),
      do: Tranches.unsupported!("tranches that add up to more than the loan")
  end

  defp store_entry!(loan, %{id: nil} = entry, _known),
    do: Tranches.insert!(loan.id, entry.date, entry.principal, loan.net_disbursal_amount)

  defp store_entry!(_loan, entry, known) do
    tranche = known[entry.id]
    if tranche.disbursed_on == nil, do: change!(tranche, entry), else: :ok
  end

  defp change!(tranche, entry) do
    if tranche.expected_date != entry.date or not Decimal.eq?(tranche.principal, entry.principal),
      do: Tranches.update!(tranche.id, entry.date, entry.principal)
  end

  @doc "Changes the date and amount of tranche `disbursement_id` of loan `id`."
  @spec update_one!(struct, integer, integer, Params.t()) :: Result.t()
  def update_one!(_user, id, disbursement_id, %Params{} = p) do
    Params.check_supported!(p, @one_supported)
    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    check_charged_off!(loan)

    tranche = Tranches.get(id, disbursement_id)
    if tranche == nil or tranche.is_reversed, do: raise(ServerError)

    expected = Params.date(p, "expectedDisbursementDate")
    updated_date = Params.date(p, "updatedExpectedDisbursementDate")
    updated_principal = Params.decimal_with_locale(p, "updatedPrincipal")

    "loan.update.disbursement"
    |> Validation.new()
    |> Validation.param("expectedDisbursementDate", expected)
    |> Validation.not_null()
    |> Validation.param("principal", updated_principal)
    |> Validation.not_null()
    |> already_paid(tranche)
    |> Validation.raise_if_errors!()

    if Params.exists?(p, "disbursementData"),
      do: Tranches.unsupported!("a list of tranches with the change of one")

    check_open!(loan)

    cond do
      loan.loan_status_id not in [100, @approved] ->
        Tranches.unsupported!("changing a tranche of a loan that is paid out")

      updated_date == nil ->
        Tranches.unsupported!("a change of a tranche without its new date")

      true ->
        Tranches.update!(tranche.id, updated_date, updated_principal)
    end

    result(loan, %{
      "expectedDisbursementDate" => Params.string(p, "expectedDisbursementDate"),
      "id" => ""
    })
  end

  defp already_paid(v, %{disbursed_on: nil}), do: v

  defp already_paid(v, _tranche) do
    v
    |> Validation.param("expectedDisbursementDate", nil)
    |> Validation.fail_with_code("can.not.change.disbursement.date")
  end

  defp check_open!(%{loan_status_id: status}) when status in @closed do
    "loan.update.disbursement"
    |> Validation.new()
    |> Validation.add_error(
      "error.msg.loan.edit.disbursement.account.is.not.active",
      "Edit disbursement is not allowed. Loan Account is not active.",
      "id",
      []
    )
    |> Validation.raise_if_errors!()
  end

  defp check_open!(_loan), do: :ok

  defp result(loan, changes) do
    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: loan.id,
      changes: changes
    )
  end

  defp refuse!(code, message),
    do: raise(DomainRuleViolation, code: code, message: message, args: [])
end
