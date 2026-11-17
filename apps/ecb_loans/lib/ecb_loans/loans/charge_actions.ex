defmodule ECBLoans.Loans.ChargeActions do
  @moduledoc """
  What can be done to the charges of a loan once it exists (`/loans/{id}/charges`): add one, waive one, change
  or delete one while the loan awaits approval, and the refusals of paying one. Follows Fineract's
  `LoanChargeWritePlatformServiceImpl`.

  A loan that has been paid out takes a new charge into the schedule it has: a charge on a date goes into the
  installment that holds the date (a date after the last installment gets an installment of its own, with
  nothing to pay but the charge), an installment fee into every installment. The repayments made so far are then
  worked out again, so they pay the new charge too. A loan that has not been paid out has its schedule worked
  out again with the charge in it.

  Not supported yet, and refused as such: charges that fall due when a loan is overdue or by tranche, charges on a
  loan that is closed, overpaid or has a due date after the loan's last installment before it is paid out, and
  charges on a loan with accrual accounting.
  """
  import Ecto.Query

  alias ECBLoans.Loans

  alias ECBLoans.Loans.{
    Accruals,
    ChargeRows,
    Derived,
    Disburse,
    Repay,
    Reprocess,
    Transitions
  }

  alias ECBLoans.Schedule.ChargeInput
  alias ECBPlatform.{BusinessDate, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @pending 100
  @approved 200
  @active 300

  @waive_charges 9

  @add_supported ~w(chargeId amount dueDate locale dateFormat externalId)
  @update_supported ~w(amount dueDate locale dateFormat)
  @waive_supported ~w(dueDate locale dateFormat installmentNumber externalId)
  @pay_supported ~w(transactionDate locale dateFormat dueDate installmentNumber externalId)

  # --- add -----------------------------------------------------------------------------------------------

  @doc "Adds the charge asked for to loan `id`."
  @spec add!(struct, integer, Params.t()) :: Result.t()
  def add!(user, id, %Params{} = p) do
    Params.check_supported!(p, @add_supported)
    charge_id = Json.long(p, "chargeId")
    amount = Params.decimal_with_locale(p, "amount")
    due = Params.date(p, "dueDate")

    Validation.new("loanCharge")
    |> Validation.param("chargeId", charge_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("amount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> check_due_date(p, due)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    definition = ChargeInput.definition!(charge_id)
    check_status!(loan, "Adding a charge")
    check_new!(loan, definition, due)

    entry = %{
      charge_id: definition.id,
      name: definition.name,
      time: definition.time,
      calc: definition.calculation,
      penalty: definition.penalty,
      amount: amount,
      due_date: due,
      payment_mode: definition.payment_mode,
      charge_amount: definition.amount,
      currency_code: definition.currency.code
    }

    new_id =
      if loan.loan_status_id == @active,
        do: add_to_active!(user, loan, entry),
        else: add_before_payout!(user, loan, entry)

    if external_id = Params.string(p, "externalId"),
      do:
        TenantRepo.update_all(from(c in "m_loan_charge", where: c.id == ^new_id),
          set: [external_id: external_id]
        )

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: new_id,
      resource_external_id: Params.string(p, "externalId")
    )
  end

  defp check_due_date(v, p, due) do
    if Params.exists?(p, "dueDate"),
      do: v |> Validation.param("dueDate", due) |> Validation.not_blank(),
      else: v
  end

  # a loan awaiting approval or payout, or one being repaid, takes charges; a closed one does not yet
  defp check_status!(loan, what) do
    if loan.loan_status_id not in [@pending, @approved, @active],
      do: unsupported!(what <> " to a loan that is closed or overpaid")

    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    if loan.loan_status_id == @active and product.accounting_id in [3, 4],
      do: unsupported!(what <> " to a loan with accrual accounting")

    :ok
  end

  defp unsupported!(what) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message: "#{what} is not supported yet by E-CoreBank",
      args: ["charges"]
  end

  # what makes a charge impossible to add, in the order Fineract finds it
  defp check_new!(loan, definition, due) do
    if loan.loan_status_id == @active and definition.time == 1 do
      raise DomainRuleViolation,
        code: "error.msg.charge.cannot.be.updated.no.pending.disbursements.in.loan",
        message: "This charge cannot be added, No disbursement is pending",
        args: []
    end

    if definition.time in [2, 9] and is_nil(due) do
      raise DomainRuleViolation,
        code: "error.msg.loanCharge.dueDate.cannot.be.blank",
        message: "Loan charge is missing due date.",
        args: [definition.id, definition.name]
    end

    if definition.time == 9 do
      raise DomainRuleViolation,
        code: "error.msg.loanCharge.cannot.be.added.as.overdue.charge",
        message: "Installment charge cannot be added to the loan.",
        args: [nil, definition.name]
    end

    ChargeInput.refuse!(definition, [1, 2, 8])
    disbursement = loan.disbursedon_date || loan.expected_disbursedon_date

    if due && Date.compare(due, disbursement) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loanCharge.cannot.be.added.as.date.is.before.last.transaction.date",
        message: "charge with date before last transaction date can not be added to loan.",
        args: [nil, definition.name]
    end

    :ok
  end

  # a loan not yet paid out has its schedule worked out again with the new charge among the others
  defp add_before_payout!(user, loan, entry) do
    charges = ChargeRows.params(loan.id) ++ ChargeRows.params_from([entry])
    last = Loans.installments(loan.id) |> List.last()

    if entry.time == 2 and Date.compare(entry.due_date, last.due_date) == :gt,
      do: unsupported!("A charge on a date after the last installment of a loan not yet paid out")

    Transitions.regenerate!(loan.id, user, charges: charges, append: true)
    nothing_paid!(loan.id)

    TenantRepo.one(from(c in "m_loan_charge", where: c.loan_id == ^loan.id, select: max(c.id)))
  end

  # once a charge has been changed the loan's charges all show what they have paid as an amount, not as nothing
  defp nothing_paid!(loan_id) do
    TenantRepo.update_all(
      from(c in "m_loan_charge", where: c.loan_id == ^loan_id and is_nil(c.amount_paid_derived)),
      set: [amount_paid_derived: Decimal.new(0)]
    )
  end

  defp add_to_active!(user, loan, entry) do
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    rows = Loans.installments(loan.id)
    on = BusinessDate.current()
    detail = detail(loan, product, entry, rows)

    if ECBMoney.zero?(detail.total) do
      raise DomainRuleViolation,
        code: "error.msg.loanCharge.cannot.be.added.as.amount.rounded.to.zero",
        message:
          "This charge cannot be added because the calculated amount becomes zero after rounding.",
        args: [loan.id, entry.name]
    end

    if entry.time == 2, do: ensure_installment!(user, loan.id, rows, entry.due_date)
    charge_id = ChargeRows.add!(loan.id, detail, user)
    ChargeRows.refresh_installments!(loan.id)

    if Accruals.at_disbursement?(product) do
      charge = Loans.charge(loan.id, charge_id)
      date = accrual_date(charge, on)
      Accruals.accrue_charge!(user, loan, product, charge, date)
      add_to_accrued!(loan.id, charge)
    end

    worked_out_again!(user, loan.id, on)
    charge_id
  end

  @doc "The day a charge's accrual is dated: the day it falls due, or the business date if that is still to come."
  @spec accrual_date(map, Date.t()) :: Date.t()
  def accrual_date(%{due_date: nil}, on), do: on

  def accrual_date(%{due_date: due}, on),
    do: if(Date.compare(due, on) == :gt, do: on, else: due)

  @doc "The installment holding the charge's due date has it among what it has accrued."
  @spec add_to_accrued!(integer, map) :: :ok
  def add_to_accrued!(loan_id, %{time: time} = c) when time in [2, 9] do
    column =
      if c.penalty, do: :accrual_penalty_charges_derived, else: :accrual_fee_charges_derived

    case ChargeRows.installment_of(loan_id, c.due_date) do
      nil ->
        :ok

      number ->
        TenantRepo.update_all(
          from(r in "m_loan_repayment_schedule",
            where: r.loan_id == ^loan_id and r.installment == ^number
          ),
          inc: [{column, c.amount}]
        )
    end

    :ok
  end

  def add_to_accrued!(_loan_id, _charge), do: :ok

  # --- what a charge comes to ------------------------------------------------------------------------------

  @doc "The currency of a product as money works with it."
  @spec currency_of(map) :: struct
  def currency_of(product) do
    ECBMoney.Currency.new(product.currency.code, product.currency.decimal_places,
      in_multiples_of: positive_or_nil(product.currency.multiples_of)
    )
  end

  defp detail(loan, product, entry, rows) do
    currency = currency_of(product)
    context = ECBMoney.Context.new(:half_even)
    money = &ECBMoney.new(currency, &1, context)
    principal = money.(loan.principal_amount)
    interest = money.(sum(rows, & &1.interest))
    loan_base = base_of(entry.calc, principal, interest)
    amount_for = &amount_on(entry, &1, money)

    installments =
      if entry.time == 8 do
        for r <- rows do
          base = base_of(entry.calc, money.(r.principal || 0), money.(r.interest || 0))
          {r.installment, amount_for.(base)}
        end
      else
        []
      end

    total =
      if entry.time == 8,
        do:
          Enum.reduce(
            installments,
            ECBMoney.zero(currency, context),
            &ECBMoney.plus(&2, elem(&1, 1))
          ),
        else: amount_for.(loan_base)

    %{
      charge: entry,
      total: total,
      applied_to: if(entry.calc == 1, do: nil, else: ECBMoney.amount(loan_base)),
      installments: installments
    }
  end

  # what a percentage is of: the principal, the principal and interest, or the interest
  defp base_of(3, principal, interest), do: ECBMoney.plus(principal, interest)
  defp base_of(4, _principal, interest), do: interest
  defp base_of(_calc, principal, _interest), do: principal

  # a flat charge is its amount, a percentage the percentage of a base
  defp amount_on(%{calc: 1, amount: amount}, _base, money), do: money.(amount)

  defp amount_on(%{amount: percentage}, base, _money),
    do: ECBMoney.percentage_of(base, percentage)

  defp positive_or_nil(nil), do: nil
  defp positive_or_nil(n) when n > 0, do: n
  defp positive_or_nil(_), do: nil

  defp sum(rows, fun) do
    Enum.reduce(rows, Decimal.new(0), fn r, acc -> Decimal.add(acc, fun.(r) || 0) end)
  end

  # a date after the last installment gets an installment of its own (or moves the one made for an earlier one)
  defp ensure_installment!(user, loan_id, rows, due) do
    last = List.last(rows)

    if Date.compare(due, last.due_date) == :gt do
      additional? =
        TenantRepo.one(
          from(r in "m_loan_repayment_schedule", where: r.id == ^last.id, select: r.is_additional)
        )

      if additional? do
        TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^last.id),
          set: [duedate: due]
        )
      else
        now = DateTime.utc_now()

        TenantRepo.insert_all("m_loan_repayment_schedule", [
          %{
            loan_id: loan_id,
            fromdate: last.due_date,
            duedate: due,
            installment: last.installment + 1,
            completed_derived: false,
            recalculated_interest_component: false,
            is_additional: true,
            is_down_payment: false,
            is_re_aged: false,
            created_by: user.id,
            last_modified_by: user.id,
            created_on_utc: now,
            last_modified_on_utc: now
          }
        ])
      end
    end

    :ok
  end

  @doc "The repayments made so far are worked out again so they pay the charges as they now stand."
  @spec worked_out_again!(struct, integer, Date.t()) :: :ok
  def worked_out_again!(user, loan_id, on) do
    if repayments?(loan_id) do
      Reprocess.run!(user, loan_id)
    else
      ChargeRows.sync_paid!(loan_id)
      Derived.refresh!(loan_id, user)
      Repay.after_repayment!(user, Loans.fetch!(loan_id), on, Decimal.new(0))
    end

    :ok
  end

  defp repayments?(loan_id) do
    TenantRepo.exists?(
      from(t in "m_loan_transaction",
        where: t.loan_id == ^loan_id and not t.is_reversed and t.transaction_type_enum in [2, 4]
      )
    )
  end

  # --- waive ----------------------------------------------------------------------------------------------

  @doc "Waives what is outstanding of charge `charge_id` of loan `id` (of one installment, for an installment fee)."
  @spec waive!(struct, integer, integer, Params.t()) :: Result.t()
  def waive!(user, id, charge_id, %Params{} = p) do
    Params.check_supported!(p, @waive_supported)
    number = Params.integer_with_locale(p, "installmentNumber")

    Validation.new("loan.charge.waive.transaction")
    |> Validation.param("installmentNumber", number)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    charge = charge!(id, charge_id)

    if loan.loan_status_id != @active,
      do:
        refuse!(
          "error.msg.loan.charge.associated.loan.inactive",
          "This loan charge cannot be waived as the loan associated with it is currently inactive",
          charge_id
        )

    check_open!(charge, charge_id)
    slot = if charge.time == 8, do: installment_charge!(charge, p, number, charge_id)
    check_status!(loan, "Waiving a charge")

    {amount, installment} = waivable(charge, slot)
    date = waive_date(loan, charge, slot)
    tx_id = make_waiver!(user, loan, charge, amount, date, installment)
    waive_rows!(charge, slot, amount)
    ChargeRows.refresh_installments!(id)
    worked_out_again!(user, id, date)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: charge_id,
      subresource_id: tx_id,
      changes: %{"amount" => amount}
    )
  end

  defp charge!(loan_id, charge_id) do
    case Loans.charge(loan_id, charge_id) do
      nil ->
        if TenantRepo.exists?(from(c in "m_loan_charge", where: c.id == ^charge_id)) do
          raise ECBPlatform.Errors.ResourceNotFound,
            code: "error.msg.loanCharge.id.invalid.for.given.loan",
            message:
              "Loan charge with identifier #{charge_id} does not exist for loan #{loan_id}",
            args: [charge_id, loan_id]
        else
          raise ECBPlatform.Errors.ResourceNotFound,
            code: "error.msg.loanCharge.id.invalid",
            message: "Loan charge with identifier #{charge_id} does not exist",
            args: [charge_id]
        end

      charge ->
        charge
    end
  end

  defp refuse!(code, message, charge_id),
    do: raise(DomainRuleViolation, code: code, message: message, args: [charge_id])

  # a charge already waived or paid in full cannot be waived or paid
  defp check_open!(charge, charge_id) do
    cond do
      charge.waived ->
        refuse!(
          "error.msg.loan.charge.already.waived",
          "This loan charge has already been waived",
          charge_id
        )

      charge.is_paid ->
        refuse!(
          "error.msg.loan.charge.already.paid",
          "This loan charge has been completely paid",
          charge_id
        )

      true ->
        :ok
    end
  end

  # the installment of an installment fee that is asked for (by date or number), or the first one not paid
  defp installment_charge!(charge, p, number, charge_id) do
    slots = Loans.installment_charges(charge.id)

    slot =
      asked_for(slots, Params.date(p, "dueDate"), number) ||
        Enum.find(slots, &(not &1.paid and not &1.waived)) || List.first(slots)

    check_slot_open!(slot, charge_id)
    slot
  end

  defp asked_for(slots, due, _number) when not is_nil(due),
    do: Enum.find(slots, &(&1.due_date == due))

  defp asked_for(slots, _due, number) when not is_nil(number),
    do: Enum.find(slots, &(&1.installment == number))

  defp asked_for(_slots, _due, _number), do: nil

  defp check_slot_open!(%{waived: true}, charge_id),
    do:
      refuse!(
        "error.msg.loan.charge.already.waived",
        "This loan charge has already been waived",
        charge_id
      )

  defp check_slot_open!(%{paid: true}, charge_id),
    do:
      refuse!(
        "error.msg.loan.charge.already.paid",
        "This loan charge has been completely paid",
        charge_id
      )

  defp check_slot_open!(_slot, _charge_id), do: :ok

  defp waivable(charge, nil), do: {charge.outstanding, nil}
  defp waivable(_charge, slot), do: {slot.outstanding, slot.installment}

  # the day the waiver is dated: the day the charge fell due, or the business date if that is still to come
  defp waive_date(loan, %{time: time, due_date: due}, _slot) when time in [2, 9],
    do: not_after_today(due, loan)

  defp waive_date(loan, %{time: 8}, slot), do: not_after_today(slot.due_date, loan)
  defp waive_date(loan, _charge, _slot), do: loan.disbursedon_date

  defp not_after_today(date, _loan) do
    today = BusinessDate.current()
    if Date.compare(date, today) == :gt, do: today, else: date
  end

  defp make_waiver!(user, loan, charge, amount, date, installment) do
    tx = %{
      type: @waive_charges,
      date: date,
      amount: amount,
      balance: loan.principal_outstanding_derived
    }

    tx = if charge.penalty, do: Map.put(tx, :penalties, amount), else: Map.put(tx, :fees, amount)
    id = Disburse.insert_transaction!(user, loan, tx)
    ChargeRows.record_paid_by!(id, charge.id, amount, installment)
    id
  end

  # the charge (or the installment of it) is now waived
  defp waive_rows!(charge, nil, amount) do
    TenantRepo.update_all(from(c in "m_loan_charge", where: c.id == ^charge.id),
      set: [
        amount_waived_derived: amount,
        amount_outstanding_derived: Decimal.new(0),
        is_paid_derived: false,
        waived: true
      ]
    )
  end

  defp waive_rows!(charge, slot, amount) do
    TenantRepo.update_all(from(i in "m_loan_installment_charge", where: i.id == ^slot.id),
      set: [
        amount_waived_derived: amount,
        amount_outstanding_derived: Decimal.new(0),
        is_paid_derived: false,
        waived: true
      ]
    )

    all_done? =
      charge.id
      |> Loans.installment_charges()
      |> Enum.all?(&(&1.id == slot.id or &1.paid or &1.waived))

    TenantRepo.update_all(
      from(c in "m_loan_charge",
        where: c.id == ^charge.id,
        update: [
          set: [
            waived: ^all_done?,
            amount_waived_derived:
              fragment("coalesce(?, 0) + ?", c.amount_waived_derived, ^amount),
            amount_outstanding_derived: fragment("? - ?", c.amount_outstanding_derived, ^amount)
          ]
        ]
      ),
      []
    )
  end

  # --- pay -------------------------------------------------------------------------------------------------

  @doc """
  Paying a charge by itself is for charges paid by account transfer, which E-CoreBank does not take yet: this
  checks the request as Fineract does and refuses it for the reason Fineract would.
  """
  @spec pay!(struct, integer, integer, Params.t()) :: no_return
  def pay!(_user, id, charge_id, %Params{} = p) do
    Params.check_supported!(p, @pay_supported)
    number = Params.integer_with_locale(p, "installmentNumber")

    Validation.new("loan.charge.payment.transaction")
    |> Validation.param("transactionDate", Params.date(p, "transactionDate"))
    |> Validation.not_null()
    |> Validation.param("installmentNumber", number)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    charge = charge!(id, charge_id)

    if loan.loan_status_id != @active,
      do:
        refuse!(
          "error.msg.loan.charge.associated.loan.inactive",
          "This loan charge cannot be paid as the loan associated with it is currently inactive",
          charge_id
        )

    check_open!(charge, charge_id)

    refuse!(
      "error.msg.loan.charge.payment.mode.not.account.transfer",
      "This loan charge cannot be paid as the charge payment mode is not account transfer",
      charge_id
    )
  end

  # --- adjustment ------------------------------------------------------------------------------------------

  @doc "Adjusting a charge (a credit against what was paid of it) is not built yet."
  @spec adjust!(struct, integer, integer, Params.t()) :: no_return
  def adjust!(_user, id, charge_id, %Params{}) do
    loan = Loans.fetch!(id)
    charge!(id, charge_id)
    check_status!(loan, "Adjusting a charge")
    unsupported!("Adjusting a charge")
  end

  # --- change and delete before approval ---------------------------------------------------------------------

  @doc "Changes the amount or due date of a charge of a loan awaiting approval."
  @spec update!(struct, integer, integer, Params.t()) :: Result.t()
  def update!(user, id, charge_id, %Params{} = p) do
    Params.check_supported!(p, @update_supported)
    amount = Params.decimal_with_locale(p, "amount")

    Validation.new("loanCharge")
    |> Validation.param("amount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    charge = charge!(id, charge_id)
    awaiting_approval!(loan, charge_id, "updated")

    due = if Params.exists?(p, "dueDate"), do: Params.date(p, "dueDate"), else: charge.due_date

    changes =
      %{}
      |> then(&if(due != charge.due_date, do: Map.merge(&1, date_changes(p)), else: &1))
      |> then(
        &if(Decimal.eq?(amount, charge.amount_or_percentage),
          do: &1,
          else: Map.merge(&1, %{"amount" => amount, "locale" => Params.string(p, "locale")})
        )
      )

    charges =
      for {c, param} <- Enum.zip(Loans.charges(id), ChargeRows.params(id)) do
        if c.id == charge_id,
          do:
            param
            |> Map.put("amount", amount_json(amount))
            |> Map.delete("dueDate")
            |> put_due(due),
          else: param
      end

    Transitions.regenerate!(id, user, charges: charges, append: true)
    nothing_paid!(id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: charge_id,
      changes: changes
    )
  end

  defp date_changes(p),
    do: %{
      "dueDate" => Params.string(p, "dueDate"),
      "dateFormat" => Params.string(p, "dateFormat"),
      "locale" => Params.string(p, "locale")
    }

  defp amount_json(amount), do: Jason.Fragment.new(Decimal.to_string(amount, :normal))

  defp put_due(map, nil), do: map
  defp put_due(map, due), do: Map.put(map, "dueDate", Date.to_iso8601(due))

  @doc "Deletes a charge of a loan awaiting approval."
  @spec delete!(struct, integer, integer) :: Result.t()
  def delete!(user, id, charge_id) do
    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    charge = charge!(id, charge_id)
    awaiting_approval!(loan, charge_id, "deleted")

    if charge.waived,
      do:
        refuse!(
          "error.msg.loan.charge.already.waived",
          "This loan charge has already been waived",
          charge_id
        )

    charges = ChargeRows.params(id, charge_id)
    ChargeRows.remove!(charge_id)
    Transitions.regenerate!(id, user, charges: charges, append: true)
    nothing_paid!(id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: charge_id
    )
  end

  defp awaiting_approval!(%{loan_status_id: @pending}, _charge_id, _what), do: :ok

  defp awaiting_approval!(_loan, charge_id, what) do
    refuse!(
      "error.msg.loan.charge.associated.loan.not.in.submitted.and.pending.approval.stage",
      "This charge cannot be #{what} as the loan it is associated with is not in submitted and pending approval stage",
      charge_id
    )
  end
end
