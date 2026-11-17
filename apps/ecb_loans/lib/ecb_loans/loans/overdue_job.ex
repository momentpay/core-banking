defmodule ECBLoans.Loans.OverdueJob do
  @moduledoc """
  The job "Apply penalty to overdue loans" (`LA_OPEN`), after Fineract's
  `ApplyChargeToOverdueLoanInstallmentTasklet` and `LoanChargeWritePlatformServiceImpl.applyOverdueChargesForLoan`.

  A product can carry charges that fall due when an installment is overdue (charge time 9). For every active
  loan of such a product the job adds one penalty for each installment that is more than the penalty wait period
  (`penalty-wait-period`, 2 days) past its due date and not paid in full. With `backdate-penalties-enabled` off,
  only installments that fell due within that wait period and one day more are looked at; with it on, every
  overdue installment is.

  A penalty is dated the installment's due date plus the grace on penalty posting (`grace-on-penalty-posting`).
  A charge that repeats (a fee frequency) is added again for every period that has passed since, each one with
  its own number, so a later run only adds the ones it has not added yet. A percentage is taken of what is still
  outstanding of the installment (its principal, its interest, or both) when the penalty is added.

  A penalty goes into the installment holding its date, as any charge on a date does, and the repayments made
  so far are worked out again to pay it. Where the product books accruals when a charge is added (upfront
  accrual accounting, or none and cash accounting while `allow-cash-and-non-cash-accrual` is on) the penalty is
  accrued on its date; periodic accrual accounting leaves that to the periodic accrual job.

  A loan the job cannot add penalties to (a charge it does not support yet, or a repeating penalty that would
  fall after the last installment) is left as it was and the others are done; the run then fails, naming them.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Accruals, ChargeActions, ChargeRows}
  alias ECBLoans.Schedule.{ChargeInput, Dates}
  alias ECBPlatform.{BusinessDate, Configuration, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    today = BusinessDate.current()
    settings = settings()

    failures =
      today
      |> overdue(settings)
      |> Enum.group_by(& &1.loan_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {loan_id, rows} ->
        apply_to_loan(user, loan_id, rows, today, settings)
      end)

    if failures != [] do
      raise "Apply penalty to overdue loans failed for " <>
              Enum.map_join(failures, "; ", fn {loan_id, message} ->
                "loan #{loan_id}: #{message}"
              end)
    end

    :ok
  end

  defp settings do
    %{
      wait: setting("penalty-wait-period", 2),
      grace: setting("grace-on-penalty-posting", 0),
      backdate: Configuration.enabled?("backdate-penalties-enabled")
    }
  end

  defp setting(name, default) do
    case Configuration.get(name) do
      %{value: value} when is_integer(value) -> value
      _ -> default
    end
  end

  # the installments of active loans that are overdue, with each overdue charge of the loan's product
  defp overdue(today, %{wait: wait, backdate: backdate}) do
    since = if backdate, do: "", else: " AND s.duedate >= $1::date - ($2::int + 1)"

    TenantRepo.query!(
      """
      SELECT s.loan_id, s.installment, s.id, s.duedate, c.id,
             COALESCE(s.principal_amount, 0) - COALESCE(s.principal_completed_derived, 0)
               - COALESCE(s.principal_writtenoff_derived, 0),
             COALESCE(s.interest_amount, 0) - COALESCE(s.interest_waived_derived, 0)
               - COALESCE(s.interest_writtenoff_derived, 0) - COALESCE(s.interest_completed_derived, 0)
        FROM m_loan_repayment_schedule s
        JOIN m_loan l ON l.id = s.loan_id
        JOIN m_product_loan_charge p ON p.product_loan_id = l.product_id
        JOIN m_charge c ON c.id = p.charge_id
       WHERE $1::date - $2::int > s.duedate
         AND COALESCE(s.completed_derived, false) = false
         AND COALESCE(s.recalculated_interest_component, false) = false
         AND c.charge_applies_to_enum = 1 AND c.charge_time_enum = 9
         AND l.loan_status_id = 300 AND COALESCE(l.is_charged_off, false) = false#{since}
       ORDER BY s.loan_id, s.installment, c.id
      """,
      [today, wait]
    ).rows
    |> Enum.map(fn [loan_id, installment, schedule_id, due, charge_id, principal, interest] ->
      %{
        loan_id: loan_id,
        installment: installment,
        schedule_id: schedule_id,
        due_date: due,
        charge_id: charge_id,
        principal: principal,
        interest: interest
      }
    end)
  end

  # one loan is done whole or not at all; what stops it is handed back to be reported
  defp apply_to_loan(user, loan_id, rows, today, settings) do
    {:ok, _} =
      TenantRepo.transaction(fn ->
        apply_charges!(user, loan_id, rows, today, settings)
      end)

    []
  rescue
    error -> [{loan_id, Exception.message(error)}]
  end

  defp apply_charges!(user, loan_id, rows, today, settings) do
    loan = Loans.fetch!(loan_id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    last_due = loan_id |> Loans.installments() |> List.last() |> Map.fetch!(:due_date)

    added =
      for row <- rows,
          definition = ChargeInput.definition!(row.charge_id),
          _ = ChargeInput.refuse!(definition, [9]),
          {number, date} <- new_dates(loan_id, definition, row, today, settings) do
        if Date.compare(date, last_due) == :gt, do: after_last_installment!(date)
        add_charge!(user, loan, product, definition, row, number, date)
      end

    ids = Enum.reject(added, &is_nil/1)

    if ids != [] do
      ChargeRows.refresh_installments!(loan_id)
      Enum.each(ids, &accrue!(user, loan, product, &1, today))
      ChargeActions.worked_out_again!(user, loan_id, today)
    end

    :ok
  end

  defp after_last_installment!(date) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message:
        "A penalty on #{date}, after the last installment of the loan, is not supported yet by E-CoreBank",
      args: ["charges"]
  end

  # the dates a penalty is wanted on (by frequency number) that it has not been made for yet
  defp new_dates(loan_id, definition, row, today, settings) do
    made = made(loan_id, definition.id, row.installment)

    definition
    |> wanted(row.due_date, today, settings)
    |> Enum.reject(fn {number, _date} -> number in made end)
  end

  defp made(loan_id, charge_id, installment) do
    TenantRepo.all(
      from(o in "m_loan_overdue_installment_charge",
        join: c in "m_loan_charge",
        on: c.id == o.loan_charge_id,
        join: r in "m_loan_repayment_schedule",
        on: r.id == o.loan_schedule_id,
        where:
          c.loan_id == ^loan_id and c.charge_id == ^charge_id and c.is_active == true and
            r.installment == ^installment,
        select: o.frequency_number
      )
    )
  end

  # a charge that does not repeat is made once; one that does is made for every period begun since the due date
  defp wanted(definition, due, today, %{wait: wait, grace: grace}) do
    gap = max(wait + 1 - grace, 1)
    start = Date.add(due, wait + 1)

    case definition.fee_frequency do
      nil ->
        [{1, Date.add(start, -gap)}]

      frequency ->
        repeat(start, frequency, definition.fee_interval || 1, gap, today, 1, [])
    end
  end

  defp repeat(start, frequency, every, gap, today, number, acc) do
    if Date.compare(start, today) == :gt do
      Enum.reverse(acc)
    else
      repeat(
        Dates.plus(start, frequency, every),
        frequency,
        every,
        gap,
        today,
        number + 1,
        [{number, Date.add(start, -gap)} | acc]
      )
    end
  end

  defp add_charge!(user, loan, product, definition, row, number, date) do
    currency = ChargeActions.currency_of(product)
    context = ECBMoney.Context.new(:half_even)
    money = &ECBMoney.new(currency, &1, context)

    base = base(definition.calculation, money.(row.principal), money.(row.interest))

    total =
      if definition.calculation == 1,
        do: money.(definition.amount),
        else: ECBMoney.percentage_of(base, definition.amount)

    if ECBMoney.zero?(total) do
      nil
    else
      entry = %{
        charge_id: definition.id,
        name: definition.name,
        time: 9,
        calc: definition.calculation,
        penalty: definition.penalty,
        amount: definition.amount,
        due_date: date,
        payment_mode: definition.payment_mode,
        charge_amount: definition.amount,
        currency_code: definition.currency.code
      }

      detail = %{
        charge: entry,
        total: total,
        applied_to: if(definition.calculation == 1, do: nil, else: ECBMoney.amount(base)),
        installments: []
      }

      id = ChargeRows.add!(loan.id, detail, user)

      TenantRepo.insert_all("m_loan_overdue_installment_charge", [
        %{loan_charge_id: id, loan_schedule_id: row.schedule_id, frequency_number: number}
      ])

      id
    end
  end

  # what a percentage is of: the principal, the principal and interest, or the interest still outstanding
  defp base(3, principal, interest), do: ECBMoney.plus(principal, interest)
  defp base(4, _principal, interest), do: interest
  defp base(_calc, principal, _interest), do: principal

  # a penalty is accrued on its date where the product books accruals as charges are added
  defp accrue!(user, loan, product, charge_id, today) do
    if Accruals.at_disbursement?(product) do
      charge = Loans.charge(loan.id, charge_id)

      Accruals.accrue_charge!(
        user,
        loan,
        product,
        charge,
        ChargeActions.accrual_date(charge, today)
      )

      ChargeActions.add_to_accrued!(loan.id, charge)
    end

    :ok
  end
end
