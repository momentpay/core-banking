defmodule ECBLoans.Loans.ChargeOff do
  @moduledoc """
  Charging a loan off and taking the charge-off back, following Fineract's `LoanWritePlatformServiceJpaRepositoryImpl`
  (`chargeOff`, `undoChargeOff`) and the way the transaction processor works the charge-off out
  (`recalculateChargeOffTransaction`).

  A loan is charged off on a date (not before its last transaction, not in the future, with no money moved after
  it). The charge-off transaction (type 27) carries what is still outstanding: the principal, interest, fees and
  penalties of the installments not yet paid off. Before it is made, the interest accrued on the loan is brought to
  what the loan had earned by that day: the accruals made for days after it are taken back, and an accrual (or an
  accrual adjustment, when more was accrued than earned) of the difference is made on the day. The interest earned
  is the interest of every installment due by the day, and for the installment the day falls in, what is still
  owed on it in proportion to the days gone by. Accrual stops once a loan is charged off.

  Products have only the `REGULAR` charge-off behaviour and no interest recalculation yet, so those are not looked
  at. What would make Fineract work the charge-off out again is answered with
  `error.msg.loan.feature.not.supported.yet` (see `guard!/2`).
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Accruals, Disburse, Journal, Repay}
  alias ECBParty.Lookups
  alias ECBPlatform.{BusinessDate, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @charge_off 27
  @accrual 10
  @accrual_adjustment 34
  @active 300

  # transactions that move no money (Fineract's `isNonMonetaryTransaction`), and the accrual ones
  @non_monetary [3, 7, 10, 12, 13, 14, 15, 27, 32, 34]
  @accrual_related [10, 34]

  @supported ~w(transactionDate note locale dateFormat chargeOffReasonId externalId)
  @undo_supported ~w(reversalExternalId)

  # --- charging off ---------------------------------------------------------------------------

  @doc "Charges loan `id` off as of `transactionDate`."
  @spec charge_off!(struct, integer, Params.t()) :: Result.t()
  def charge_off!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    on = Params.date(p, "transactionDate")
    note = Params.string(p, "note")
    external_id = Params.string(p, "externalId")
    reason_id = Json.long(p, "chargeOffReasonId")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.ignore_if_null()
    |> Validation.max_length(1000)
    |> Validation.param("externalId", external_id)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.param("chargeOffReasonId", reason_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    check_loan!(loan, product, on)
    reason = reason_id && Lookups.code_value!("ChargeOffReasons", reason_id)
    Repay.unique_external_id!(external_id)

    take_back_later_accruals!(user, loan, on)
    accrue_to_date!(user, loan, product, on)

    tx_id = insert!(user, loan, product, on, external_id)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [
        is_charged_off: true,
        charged_off_on_date: on,
        charge_off_reason_cv_id: reason && reason.id,
        charged_off_by_userid: user.id,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    Loans.add_note(id, loan.client_id, note, user.id, tx_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: tx_id,
      resource_external_id: external_id,
      changes:
        %{
          "transactionDate" => Params.string(p, "transactionDate"),
          "locale" => Params.string(p, "locale"),
          "dateFormat" => Params.string(p, "dateFormat")
        }
        |> put_some("chargeOffReasonId", reason && reason.id)
        |> put_text("note", note)
    )
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp put_text(map, _key, nil), do: map

  defp put_text(map, key, text),
    do: if(String.trim(text) == "", do: map, else: Map.put(map, key, text))

  # the checks, in Fineract's order
  defp check_loan!(loan, product, on) do
    id = loan.id

    if loan.loan_status_id != @active do
      refuse!(
        "error.msg.loan.is.not.active",
        "Loan: #{id} Charge-off is not allowed. Loan Account is not Active",
        [id]
      )
    end

    if loan.is_charged_off do
      refuse!(
        "error.msg.loan.is.already.charged.off",
        "Loan: #{id} is already charged-off",
        [id]
      )
    end

    if Date.compare(on, last_user_transaction_date(loan)) == :lt do
      refuse!(
        "error.msg.loan.charge.off.is.before.than.the.last.user.transaction",
        "Loan: #{id} charge-off cannot be executed. User transaction was found after the charge-off transaction date!",
        [id]
      )
    end

    if Date.compare(on, BusinessDate.current()) == :gt do
      refuse!(
        "error.msg.loan.transaction.cannot.be.a.future.date",
        "The transaction date cannot be in the future.",
        [Date.to_iso8601(on)]
      )
    end

    if monetary_activity_after?(loan, on) do
      refuse!(
        "error.msg.loan.monetary.transactions.after.charge.off",
        "Loan: #{id} charge-off cannot be executed. Loan has monetary activity after the charge-off transaction date!",
        [id]
      )
    end

    check_supported!(loan, product)
  end

  defp check_supported!(_loan, product),
    do: Journal.check_supported!(product, "Charging a loan off")

  # the latest day a user (not accrual) transaction was made, or the disbursement day
  @doc false
  def last_user_transaction_date(loan) do
    TenantRepo.all(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan.id and not t.is_reversed and
            t.transaction_type_enum not in ^@accrual_related and
            t.transaction_date > ^loan.disbursedon_date,
        select: t.transaction_date
      )
    )
    |> Enum.max(Date, fn -> loan.disbursedon_date end)
  end

  # a transaction that moves money after the day, or a charge made after it that is not paid
  defp monetary_activity_after?(loan, on) do
    TenantRepo.exists?(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan.id and not t.is_reversed and t.transaction_date > ^on and
            t.transaction_type_enum not in ^@non_monetary
      )
    ) or
      Enum.any?(Loans.charges(loan.id), fn c ->
        Decimal.compare(c.outstanding || Decimal.new(0), 0) == :gt and
          Date.compare(c.submitted_on, on) == :gt
      end)
  end

  # --- accruals -----------------------------------------------------------------------------------

  # the accruals made for days after the charge-off are taken back
  defp take_back_later_accruals!(user, loan, on) do
    later =
      TenantRepo.all(
        from(t in "m_loan_transaction",
          where:
            t.loan_id == ^loan.id and not t.is_reversed and
              t.transaction_type_enum in ^@accrual_related and t.transaction_date > ^on,
          order_by: t.id,
          select: %{id: t.id, date: t.transaction_date}
        )
      )

    Enum.each(later, &Accruals.take_back!(user, loan, &1))
  end

  # an accrual, or an accrual adjustment, of what is missing to make the accruals what the loan has earned by `on`
  defp accrue_to_date!(user, loan, product, on) do
    rows = Loans.installments(loan.id)

    if Enum.any?(rows, &(Date.compare(&1.from_date, on) != :gt)) do
      earned = interest_earned(rows, on, loan.currency_digits)
      {accrued, adjusted} = accrued_until(loan.id, on)
      missing = earned |> Decimal.sub(accrued) |> Decimal.add(adjusted)

      case Decimal.compare(missing, 0) do
        :gt ->
          Accruals.post!(user, loan, product, on, missing, portions: portions(missing))

        :lt ->
          Accruals.post_adjustment!(user, loan, product, on, Decimal.abs(missing),
            portions: portions(Decimal.abs(missing))
          )

        :eq ->
          :ok
      end
    end

    :ok
  end

  defp portions(interest),
    do: %{interest: interest, fees: Decimal.new(0), penalties: Decimal.new(0)}

  # the interest of the installments due by the day, and a share of what is owed on the one the day falls in
  defp interest_earned(rows, on, digits) do
    rows
    |> Enum.map(fn row ->
      cond do
        Date.compare(row.due_date, on) != :gt ->
          zero_nil(row.interest)

        Date.compare(row.from_date, on) != :gt ->
          in_period(row, on, digits)

        true ->
          Decimal.new(0)
      end
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp in_period(row, on, digits) do
    owed =
      zero_nil(row.interest)
      |> Decimal.sub(zero_nil(row.interest_completed))
      |> Decimal.sub(zero_nil(row.interest_waived))
      |> Decimal.sub(zero_nil(row.interest_writtenoff))

    days = Date.diff(row.due_date, row.from_date)
    gone = Date.diff(on, row.from_date)
    mc = %Decimal.Context{precision: 16, rounding: :half_even}

    Decimal.Context.with(mc, fn ->
      owed |> Decimal.div(days) |> Decimal.mult(gone)
    end)
    |> Decimal.round(digits, :half_even)
  end

  defp accrued_until(loan_id, on) do
    rows =
      TenantRepo.all(
        from(t in "m_loan_transaction",
          where:
            t.loan_id == ^loan_id and not t.is_reversed and t.transaction_date <= ^on and
              t.transaction_type_enum in ^@accrual_related,
          select: {t.transaction_type_enum, t.interest_portion_derived}
        )
      )

    sum = fn type ->
      for(
        {^type, amount} <- rows,
        amount != nil,
        reduce: Decimal.new(0),
        do: (acc -> Decimal.add(acc, amount))
      )
    end

    {sum.(@accrual), sum.(@accrual_adjustment)}
  end

  defp zero_nil(nil), do: Decimal.new(0)
  defp zero_nil(d), do: d

  # --- the charge-off transaction -----------------------------------------------------------------

  defp insert!(user, loan, product, on, external_id) do
    rows = loan.id |> Loans.installments() |> Enum.reject(&(&1.completed == true))

    principal = outstanding(rows, :principal, [:principal_completed, :principal_writtenoff])

    interest =
      outstanding(rows, :interest, [:interest_completed, :interest_writtenoff, :interest_waived])

    fees =
      outstanding(rows, :fee_charges, [
        :fee_charges_completed,
        :fee_charges_writtenoff,
        :fee_charges_waived
      ])

    penalties =
      outstanding(rows, :penalty_charges, [
        :penalty_charges_completed,
        :penalty_charges_writtenoff,
        :penalty_charges_waived
      ])

    total = principal |> Decimal.add(interest) |> Decimal.add(fees) |> Decimal.add(penalties)

    tx = %{
      type: @charge_off,
      date: on,
      amount: total,
      principal: nil_zero(principal),
      interest: nil_zero(interest),
      fees: nil_zero(fees),
      penalties: nil_zero(penalties),
      external_id: external_id
    }

    id = Disburse.insert_transaction!(user, loan, tx)
    Journal.charge_off!(user, loan, product, Map.put(tx, :id, id))
    id
  end

  # what is owed of one kind in the installments not yet paid off: what they ask less what has been done with it
  defp outstanding(rows, asked, deductions) do
    rows
    |> Enum.map(fn row ->
      Enum.reduce(deductions, zero_nil(Map.fetch!(row, asked)), fn key, left ->
        Decimal.sub(left, zero_nil(Map.fetch!(row, key)))
      end)
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp nil_zero(d), do: if(Decimal.eq?(d, 0), do: nil, else: d)

  # --- undoing a charge-off -----------------------------------------------------------------------

  @doc "Takes the charge-off of loan `id` back; only the latest user transaction of the loan can be."
  @spec undo!(struct, integer, Params.t()) :: Result.t()
  def undo!(user, id, %Params{} = p) do
    Params.check_supported!(p, @undo_supported)
    reversal = Params.string(p, "reversalExternalId")

    Validation.new("loan.transaction")
    |> Validation.param("reversalExternalId", reversal)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)

    if loan.loan_status_id != @active do
      refuse!(
        "error.msg.loan.is.not.active",
        "Loan: #{id} Undo Charge-off is not allowed. Loan Account is not Active",
        [id]
      )
    end

    unless loan.is_charged_off do
      refuse!("error.msg.loan.is.not.charged.off", "Loan: #{id} is not charged-off", [id])
    end

    tx = charge_off_transaction!(loan)

    if later_user_transaction?(loan, tx) do
      refuse!(
        "error.msg.loan.charge.off.is.not.the.last.user.transaction",
        "Loan: #{id} charge-off cannot be undone. User transaction was found after charge-off!",
        [id]
      )
    end

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
      set: [
        is_reversed: true,
        reversal_external_id: reversal,
        reversed_on_date: BusinessDate.current(),
        manually_adjusted_or_reversed: true,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [
        is_charged_off: false,
        charged_off_on_date: nil,
        charge_off_reason_cv_id: nil,
        charged_off_by_userid: nil,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    Journal.reverse!(user, Loans.fetch!(id), tx.id, tx.transaction_date)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: tx.id,
      resource_external_id: tx.external_id
    )
  end

  defp charge_off_transaction!(loan) do
    case loan.id
         |> Loans.transactions()
         |> Enum.find(&(&1.transaction_type_enum == @charge_off and not &1.is_reversed)) do
      nil ->
        refuse!(
          "error.msg.loan.charge.off.transaction.not.found",
          "Loan: #{loan.id} charge-off transaction was not found",
          [loan.id]
        )

      tx ->
        tx
    end
  end

  # a transaction (not an accrual) that follows the charge-off in the order of the loan
  defp later_user_transaction?(loan, tx) do
    loan.id
    |> Loans.transactions()
    |> Enum.any?(fn t ->
      not t.is_reversed and t.transaction_type_enum not in @accrual_related and t.id != tx.id and
        after?(t, tx)
    end)
  end

  defp after?(a, b),
    do:
      Date.compare(a.transaction_date, b.transaction_date) == :gt or
        (Date.compare(a.transaction_date, b.transaction_date) == :eq and a.id > b.id)

  # --- what a charged-off loan lets be done ------------------------------------------------------

  @doc """
  Whether loan `loan` is charged off on `date`: the day is not before the charge-off, so what is made on it follows
  the accounting of a charged-off loan.
  """
  @spec charged_off_on?(map, Date.t()) :: boolean
  def charged_off_on?(%{is_charged_off: true, charged_off_on_date: from}, date),
    do: Date.compare(date, from) != :lt

  def charged_off_on?(_loan, _date), do: false

  @doc """
  Refuses `what` on a charged-off loan. A charged-off loan takes the transactions it takes without Fineract working
  the charge-off out again or posting other entries: repayments, refunds and goodwill credits dated from the
  charge-off on (`guard_date!/2`), the undoing of such a transaction on a loan with periodic or upfront accrual
  accounting (`guard_change!/3`), and an interest waiver on a loan without accounting (`guard_waiver!/1`). The
  rest is not built yet.
  """
  @spec guard!(map, String.t()) :: :ok
  def guard!(%{is_charged_off: true}, what), do: unsupported!(what <> " on a charged-off loan")
  def guard!(_loan, _what), do: :ok

  @doc "Refuses a repayment-like transaction dated before the charge-off (Fineract works the charge-off out again)."
  @spec guard_date!(map, Date.t()) :: :ok
  def guard_date!(%{is_charged_off: true, charged_off_on_date: from}, on) do
    if Date.compare(on, from) == :lt,
      do: unsupported!("A transaction dated before the charge-off date of the loan"),
      else: :ok
  end

  def guard_date!(_loan, _on), do: :ok

  @doc """
  Refuses changing transaction `tx` of a charged-off loan, unless it is undone (`amount` of nothing), was made after
  the charge-off, and the loan has periodic or upfront accrual accounting. For the others Fineract works the
  charge-off out again, or accrues again what it has already adjusted.
  """
  @spec guard_change!(map, map, Decimal.t()) :: :ok
  def guard_change!(%{is_charged_off: true} = loan, tx, amount) do
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    if Decimal.eq?(amount, 0) and product.accounting_id in [3, 4] and
         Date.compare(tx.transaction_date, loan.charged_off_on_date) == :gt,
       do: :ok,
       else: unsupported!("Changing a transaction of a charged-off loan")
  end

  def guard_change!(_loan, _tx, _amount), do: :ok

  @doc "Refuses an interest waiver on a charged-off loan with accounting."
  @spec guard_waiver!(map) :: :ok
  def guard_waiver!(%{is_charged_off: true} = loan) do
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    if product.accounting_id in [nil, 1],
      do: :ok,
      else: unsupported!("Waiving interest on a charged-off loan with accounting")
  end

  def guard_waiver!(_loan), do: :ok

  @doc "Fineract refuses a charge on a charged-off loan."
  @spec refuse_charge!(map) :: :ok
  def refuse_charge!(%{is_charged_off: true, id: id}) do
    refuse!(
      "error.msg.loan.is.charged.off",
      "Adding charge to Loan: #{id} is not allowed. Loan Account is Charged-off",
      [id]
    )
  end

  def refuse_charge!(_loan), do: :ok

  defp refuse!(code, message, args),
    do: raise(DomainRuleViolation, code: code, message: message, args: args)

  defp unsupported!(what) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message: "#{what} is not supported yet by E-CoreBank",
      args: ["chargeOff"]
  end
end
