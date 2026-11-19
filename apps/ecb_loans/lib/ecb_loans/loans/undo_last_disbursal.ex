defmodule ECBLoans.Loans.UndoLastDisbursal do
  @moduledoc """
  Taking back the last tranche of a loan that is paid out in tranches (`undolastdisbursal`), following Fineract's
  `undoLastLoanDisbursal`.

  The tranche is paid out no more and does not count; the loan is for what the tranches that stand come to; the
  schedule is worked out again from them, what was repaid is applied to it again, and the interest booked as
  accrued at disbursement is replaced if the loan's interest has changed. Refused with Fineract's errors when the
  product does not pay out in tranches, when fewer than two have been paid out, and when something was repaid
  or waived after the tranche was paid out.

  What the books of Fineract do differently and is not built is refused as not supported yet: another tranche
  still to be paid out (the loan it leaves is not one worth copying), a repayment on the day of the tranche, and
  a disbursement that paid out several tranches at once.
  """
  import Ecto.Query

  alias ECBLoans.Loans

  alias ECBLoans.Loans.{
    Arrears,
    ChargeRows,
    Foreclosure,
    Journal,
    Repay,
    Reprocess,
    Transitions
  }

  alias ECBLoans.Tranches
  alias ECBPlatform.{BusinessDate, Params, TenantRepo}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  # repayments, merchant refunds, payout refunds, goodwill credits, recoveries and the waivers: what may not
  # have happened after the tranche was paid out
  @after_tranche [2, 4, 8, 9, 21, 22, 23, 31]

  @doc "Takes the last tranche of loan `id` back."
  @spec undo!(struct, integer, Params.t()) :: Result.t()
  def undo!(user, id, %Params{} = p) do
    loan = Loans.fetch!(id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    check_multi!(product)
    check_two_paid!(id)
    Repay.active_client!(loan)
    check_charged_off!(loan)
    check_active!(loan)

    last = last_disbursement!(id)
    check_after!(loan, last)
    tranche = tranche_of!(id, last)
    check_supported!(id, last)
    Journal.check_supported!(product, "Undoing the last disbursal")

    arrears = Arrears.snapshot(id)
    replayed? = Reprocess.any?(id)
    Journal.reverse!(user, loan, last.id, last.transaction_date)

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^last.id),
      set: [is_reversed: true, reversed_on_date: BusinessDate.current()]
    )

    Tranches.reverse!(tranche.id)
    principal = disbursed_amount(id)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [
        principal_amount: principal,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    fees_paid = ChargeRows.disbursement_charges(id)
    Transitions.regenerate!(id, user, disbursed_on: loan.disbursedon_date)
    ChargeRows.restore_disbursement_charges!(fees_paid)
    Reprocess.run!(user, id)
    Foreclosure.make_accruals_again!(user, Loans.fetch!(id), product)
    # Fineract brings the arrears up to date only by working repayments out again
    if not replayed?, do: Arrears.restore!(id, arrears)
    Loans.add_note(id, loan.client_id, Params.string(p, "note"), user.id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: id,
      resource_external_id: loan.external_id,
      changes:
        %{"undolastdisbursal" => "true", "disbursedAmount" => principal}
        |> put_text("note", Params.string(p, "note"))
    )
  end

  defp check_multi!(product) do
    if not ECBLoans.Schedule.TrancheInput.multi?(product) do
      refuse!(
        "error.msg.loan.product.does.not.support.multiple.disbursals.cannot.undo.last.disbursal",
        "loan.product.does.not.support.multiple.disbursals.cannot.undo.last.disbursal",
        []
      )
    end
  end

  defp check_two_paid!(id) do
    if length(Enum.reject(Tranches.list(id), &is_nil(&1.disbursed_on))) <= 1 do
      refuse!(
        "error.msg.tranches.should.be.disbursed.more.than.one.to.undo.last.disbursal",
        "tranches.should.be.disbursed.more.than.one.to.undo.last.disbursal",
        []
      )
    end
  end

  defp check_charged_off!(%{is_charged_off: true} = loan) do
    refuse!(
      "error.msg.loan.is.charged.off",
      "Undo Loan: #{loan.id} last disbursement is not allowed. Loan Account is Charged-off",
      [loan.id]
    )
  end

  defp check_charged_off!(_loan), do: :ok

  defp check_active!(%{loan_status_id: 300}), do: :ok

  defp check_active!(loan),
    do: Tranches.guard!(loan.id, "undoing the last disbursal of a loan that is not active")

  # the last disbursement made: the one with the highest id
  defp last_disbursement!(id) do
    TenantRepo.one!(
      from(t in "m_loan_transaction",
        where: t.loan_id == ^id and t.transaction_type_enum == 1 and not t.is_reversed,
        order_by: [desc: t.id],
        limit: 1,
        select: %{id: t.id, transaction_date: t.transaction_date, amount: t.amount}
      )
    )
  end

  # nothing repaid or waived after the day the tranche was paid out
  defp check_after!(loan, last) do
    latest =
      TenantRepo.one(
        from(t in "m_loan_transaction",
          where:
            t.loan_id == ^loan.id and not t.is_reversed and
              t.transaction_type_enum in ^@after_tranche and
              t.transaction_date > ^last.transaction_date,
          order_by: [desc: t.transaction_date, desc: t.id],
          limit: 1,
          select: t.id
        )
      )

    if latest do
      refuse!(
        "error.msg.cannot.undo.last.disbursal.after.repayments or waivers",
        " Cannot undo last disbursement after repayments or waivers.",
        [latest]
      )
    end
  end

  # the tranche the last disbursement paid out: the one paid out on its day for its amount
  defp tranche_of!(id, last) do
    paid =
      Enum.filter(
        Tranches.list(id),
        &(&1.disbursed_on == last.transaction_date and Decimal.eq?(&1.principal, last.amount))
      )

    case paid do
      [tranche] -> tranche
      _ -> Tranches.unsupported!("undoing a disbursal that paid out several tranches")
    end
  end

  # what is left to guard against, besides a tranche still to be paid
  defp check_supported!(id, last) do
    if Tranches.pending(id) != [],
      do:
        Tranches.guard!(id, "undoing the last disbursal while a tranche is still to be paid out")

    same_day =
      TenantRepo.exists?(
        from(t in "m_loan_transaction",
          where:
            t.loan_id == ^id and not t.is_reversed and t.transaction_type_enum in ^@after_tranche and
              t.transaction_date == ^last.transaction_date and t.id > ^last.id
        )
      )

    if same_day,
      do: Tranches.guard!(id, "undoing a disbursal that has repayments on its day")
  end

  # what the tranches that stand come to: the loan is for no more
  defp disbursed_amount(id) do
    id
    |> Tranches.list()
    |> Enum.reject(&is_nil(&1.disbursed_on))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.principal))
  end

  defp refuse!(code, message, args),
    do: raise(DomainRuleViolation, code: code, message: message, args: args)

  defp put_text(map, _key, nil), do: map

  defp put_text(map, key, text),
    do: if(String.trim(text) == "", do: map, else: Map.put(map, key, text))
end
