defmodule ECBLoans.Loans.ChargeRefund do
  @moduledoc """
  Refunding what a loan charge has been paid (`POST /loans/{id}/transactions?command=chargeRefund`), following
  Fineract's `LoanChargeWritePlatformServiceImpl.loanChargeRefund`.

  The refund is a transaction of its own (type 24) dated the business date, for the amount asked for or all that
  can be refunded of the charge (what was paid of it less what was refunded before; of one installment for an
  installment fee). It is applied to the loan's installments as a repayment is, and the charge it refunds is
  recorded against it with the amount negated. A refund is worked out by the accounting as a repayment is, with a
  pair of entries more: the income from fees (or penalties) is given up, and the fund source is credited.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{ChargeActions, Repay}
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.Json
  alias ECBPlatform.Params
  alias ECBPlatform.Params.DatePattern
  alias ECBPlatform.TenantRepo
  alias ECBPlatform.Validation

  @supported ~w(loanChargeId dueDate installmentNumber transactionAmount externalId note locale dateFormat
                paymentTypeId accountNumber checkNumber routingCode receiptNumber bankNumber)
  @open [300, 600, 700]

  @doc "Refunds a charge of loan `id` as the request says."
  @spec refund!(struct, integer, Params.t()) :: ECBPlatform.Commands.Result.t()
  def refund!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    charge_id = Json.long(p, "loanChargeId")
    number = Params.integer_with_locale(p, "installmentNumber")
    amount = Params.decimal_with_locale(p, "transactionAmount")
    due = Params.date(p, "dueDate")

    Validation.new("loan.charge.refund.transaction")
    |> Validation.param("loanChargeId", charge_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("installmentNumber", number)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("transactionAmount", amount)
    |> Validation.ignore_if_null()
    |> Validation.positive_amount()
    |> Validation.raise_if_errors!()

    charge = ChargeActions.charge!(id, charge_id)
    loan = Loans.fetch!(id)
    slot = entrance!(loan, charge, number, due)
    refundable = refundable!(loan, charge, slot, amount)

    pattern = Params.string(p, "dateFormat") || "dd MMMM yyyy"

    request =
      p
      |> Map.get(:map)
      |> Map.drop(["loanChargeId", "installmentNumber", "dueDate"])
      |> Map.put("dateFormat", pattern)
      |> Map.put("transactionDate", DatePattern.format(BusinessDate.current(), pattern))
      |> then(&if(amount, do: &1, else: Map.put(&1, "transactionAmount", plain(refundable))))
      |> Jason.encode!()
      |> Params.parse!()

    Repay.repay!(user, id, request, 24,
      refund: %{charge: charge.id, penalty: charge.penalty, installment: slot && slot.installment}
    )
  end

  # the loan must be open or closed; an installment fee needs the installment named, and one that is not does not
  defp entrance!(loan, charge, number, due) do
    if loan.loan_status_id not in @open,
      do:
        Repay.refuse_not_supported!(
          "A charge refund on a loan that is not active",
          "chargeRefund"
        )

    if due != nil and number != nil,
      do:
        refuse!(
          "loan.charge.refund.dueDate.and.installmentNumber.provided.use.only.one",
          number,
          due
        )

    if charge.time == 8,
      do: installment_slot!(charge, number, due),
      else: not_installment!(number, due)
  end

  defp installment_slot!(charge, number, due) do
    if due == nil and number == nil do
      refuse!(
        "loan.charge.refund.neither.dueDate.nor.installmentNumber.provided.for.this.installment.charge",
        number,
        due
      )
    end

    slot =
      Enum.find(
        Loans.installment_charges(charge.id),
        &(&1.due_date == due or &1.installment == number)
      )

    if slot == nil, do: refuse!("loan.charge.refund.installment.not.found", number, due)
    slot
  end

  defp not_installment!(number, due) do
    if due != nil or number != nil do
      refuse!(
        "loan.charge.refund.dueDate.or.installmentNumber.provided.but.this.is.not.an.installment.charge",
        number,
        due
      )
    end

    nil
  end

  # what was paid of the charge (of the installment) less what was refunded, as Fineract works it out; more than that
  # cannot be asked for
  defp refundable!(loan, charge, slot, amount) do
    digits = loan.currency_digits
    paid = Decimal.round(if(slot, do: slot.paid_amount, else: charge.paid) || 0, digits)
    refunded = refunded(charge.id, slot && slot.installment)

    refundable = if refunded, do: Decimal.sub(paid, refunded), else: paid

    if amount != nil and Decimal.gt?(amount, refundable) do
      raise DomainRuleViolation,
        code: "error.msg.loan.charge.transaction.amount.is.more.than.is.refundable",
        message: "loan.charge.transaction.amount.is.more.than.is.refundable",
        args: ["transactionAmount: #{plain(amount)}  Refundable: #{plain(refundable)}"]
    end

    refundable
  end

  # what earlier refunds gave back of the charge, as a positive amount; `nil` when there were none
  defp refunded(charge_id, installment) do
    query =
      from(b in "m_loan_charge_paid_by",
        join: t in "m_loan_transaction",
        on: t.id == b.loan_transaction_id,
        where:
          b.loan_charge_id == ^charge_id and t.transaction_type_enum == 24 and not t.is_reversed and
            b.amount < 0,
        select: sum(b.amount)
      )

    query =
      if installment, do: where(query, [b], b.installment_number == ^installment), else: query

    case TenantRepo.one(query) do
      nil -> nil
      total -> Decimal.negate(total)
    end
  end

  defp refuse!(code, number, due) do
    raise DomainRuleViolation,
      code: "error." <> "msg." <> code,
      message: code,
      args: [
        "dueDate: #{if due, do: Date.to_iso8601(due), else: ""}  installmentNumber: #{number || ""}"
      ]
  end

  defp plain(decimal), do: Decimal.to_string(decimal, :normal)
end
