defmodule ECBLoans.Loans.ChargeRows do
  @moduledoc """
  The charges a loan carries (`m_loan_charge`) and what each comes to in each installment
  (`m_loan_installment_charge`), kept in step with the repayment schedule.

  Whenever a schedule is worked out for a loan (a new application, a changed one, an approval for another
  amount, a payout) its charges are worked out with it (`ECBLoans.Schedule.Charges`) and stored here: a new loan
  gets its rows, an existing one has the amounts of its rows set again and its installment charges replaced.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc """
  Stores the charges of `schedule` for loan `loan_id` onto the loan's rows in the order they were made, or, when a
  different set of charges is given, replacing them (`replace: true`). With `append: true` the rows the loan has
  keep their ids and any charges beyond them are added as new rows. Also keeps the loan's total of charges due at
  disbursement. New rows are dated by the business date.
  """
  @spec store!(integer, map, struct, keyword) :: :ok
  def store!(loan_id, schedule, user, opts) do
    details = Map.get(schedule, :charge_details, [])
    replace? = Keyword.get(opts, :replace, false)
    existing = if replace?, do: [], else: rows(loan_id)

    ids =
      if Keyword.get(opts, :append, false) do
        {old, new} = Enum.split(details, length(existing))

        Enum.map(Enum.zip(old, existing), fn {d, row} -> update!(row, d) end) ++
          Enum.map(new, &insert!(loan_id, &1, user, %{amount_paid_derived: Decimal.new(0)}))
      else
        ids_for(loan_id, details, existing, user)
      end

    installment_charges!(loan_id, details, ids)
    set_due_at_disbursement!(loan_id, schedule)
    :ok
  end

  defp ids_for(loan_id, details, existing, user) do
    if length(existing) == length(details) and existing != [] do
      details |> Enum.zip(existing) |> Enum.map(fn {d, row} -> update!(row, d) end)
    else
      delete_all!(loan_id)
      Enum.map(details, &insert!(loan_id, &1, user))
    end
  end

  @doc """
  The loan's stored charges said the way a request would say them (`chargeId`, `amount`, `dueDate`), in the order
  they were made, with dates as `yyyy-MM-dd`.
  """
  @spec params(integer, integer | nil) :: [map]
  def params(loan_id, except \\ nil) do
    from(c in "m_loan_charge",
      where: c.loan_id == ^loan_id and c.id != ^(except || 0),
      order_by: c.id,
      select: %{
        charge_id: c.charge_id,
        amount: c.charge_amount_or_percentage,
        due_date: c.due_for_collection_as_of_date
      }
    )
    |> TenantRepo.all()
    |> Enum.map(&param(&1.charge_id, &1.amount, &1.due_date))
  end

  @doc "Charges as parsed from a request (`ChargeInput.parse!/1`), said the way a request would say them."
  @spec params_from([map]) :: [map]
  def params_from(charges),
    do: Enum.map(charges, &param(&1.charge_id, &1.amount, &1.due_date))

  defp param(charge_id, amount, due_date) do
    %{"chargeId" => charge_id, "amount" => Jason.Fragment.new(Decimal.to_string(amount, :normal))}
    |> then(&if(due_date, do: Map.put(&1, "dueDate", Date.to_iso8601(due_date)), else: &1))
  end

  @doc "The charges due when the loan is paid out and not yet paid: `[%{id, amount}]`."
  @spec due_at_disbursement(integer) :: [map]
  def due_at_disbursement(loan_id) do
    TenantRepo.all(
      from(c in "m_loan_charge",
        where:
          c.loan_id == ^loan_id and c.charge_time_enum == 1 and c.is_active == true and
            c.is_paid_derived == false,
        order_by: c.id,
        select: %{id: c.id, amount: c.amount_outstanding_derived}
      )
    )
  end

  @doc "Marks the charges paid by transaction `tx_id`, each in full."
  @spec pay_in_full!(integer, [map]) :: :ok
  def pay_in_full!(tx_id, charges) do
    for c <- charges do
      TenantRepo.update_all(from(m in "m_loan_charge", where: m.id == ^c.id),
        set: [
          amount_paid_derived: c.amount,
          amount_outstanding_derived: Decimal.new(0),
          is_paid_derived: true
        ]
      )

      TenantRepo.insert_all("m_loan_charge_paid_by", [
        %{loan_transaction_id: tx_id, loan_charge_id: c.id, amount: c.amount}
      ])
    end

    :ok
  end

  @doc """
  Works out again what has been paid of each charge from what has been paid of each installment, and stores it.
  Each installment's paid fees (and penalties) go to the charges that fall in it, the oldest charge first.
  Returns what is paid of each charge, as `%{loan_charge_id => amount}`.
  """
  @spec sync_paid!(integer) :: %{integer => Decimal.t()}
  def sync_paid!(loan_id) do
    slots = slots(loan_id)

    paid =
      for row <- ECBLoans.Loans.installments(loan_id), penalty? <- [false, true], reduce: %{} do
        acc ->
          completed = (penalty? && row.penalty_charges_completed) || row.fee_charges_completed

          in_row =
            Enum.filter(slots, &(&1.installment == row.installment and &1.penalty == penalty?))

          pay_slots(in_row, completed || Decimal.new(0), acc)
      end

    store_paid!(slots, paid)
    sum_by_charge(paid)
  end

  @doc """
  What each charge asks of each installment: `%{charge, slot, installment, amount, penalty, due}`, oldest charge
  first. Installment fees come from their rows and fall due with their installment; a charge on a date falls
  due on that date, in the installment that holds it.
  """
  @spec slots(integer) :: [map]
  def slots(loan_id) do
    installment_rows =
      from(i in "m_loan_installment_charge",
        join: c in "m_loan_charge",
        on: c.id == i.loan_charge_id,
        join: r in "m_loan_repayment_schedule",
        on: r.id == i.loan_schedule_id,
        where: c.loan_id == ^loan_id and c.is_active == true,
        select: %{
          charge: c.id,
          slot: i.id,
          installment: r.installment,
          amount: i.amount,
          waived: i.amount_waived_derived,
          penalty: c.is_penalty,
          due: r.duedate
        }
      )
      |> TenantRepo.all()
      |> Enum.map(&net_of_waived/1)

    dated =
      from(c in "m_loan_charge",
        where: c.loan_id == ^loan_id and c.charge_time_enum == 2 and c.is_active == true,
        select: %{
          charge: c.id,
          amount: c.amount,
          waived: c.amount_waived_derived,
          penalty: c.is_penalty,
          due: c.due_for_collection_as_of_date
        }
      )
      |> TenantRepo.all()
      |> Enum.map(fn c ->
        net_of_waived(%{
          charge: c.charge,
          slot: nil,
          installment: installment_of(loan_id, c.due),
          amount: c.amount,
          waived: c.waived,
          penalty: c.penalty,
          due: c.due
        })
      end)

    Enum.sort_by(installment_rows ++ dated, & &1.charge)
  end

  # what a slot asks for is its amount less what was waived of it
  defp net_of_waived(%{waived: nil} = slot), do: Map.delete(slot, :waived)

  defp net_of_waived(%{waived: waived, amount: amount} = slot),
    do: slot |> Map.delete(:waived) |> Map.put(:amount, Decimal.sub(amount, waived))

  defp pay_slots(slots, completed, acc) do
    {acc, _left} =
      Enum.reduce(slots, {acc, completed}, fn slot, {acc, left} ->
        take = if Decimal.compare(left, slot.amount) == :gt, do: slot.amount, else: left
        {Map.put(acc, {slot.charge, slot.slot}, take), Decimal.sub(left, take)}
      end)

    acc
  end

  defp sum_by_charge(paid) do
    Enum.reduce(paid, %{}, fn {{charge, _slot}, amount}, acc ->
      Map.update(acc, charge, amount, &Decimal.add(&1, amount))
    end)
  end

  defp store_paid!(slots, paid) do
    totals = sum_by_charge(paid)

    for {charge, amount} <- totals do
      total =
        slots
        |> Enum.filter(&(&1.charge == charge))
        |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))

      set_charge_paid!(charge, amount, total)
    end

    for %{slot: slot} = s when not is_nil(slot) <- slots do
      amount = Map.get(paid, {s.charge, slot}, Decimal.new(0))

      TenantRepo.update_all(from(i in "m_loan_installment_charge", where: i.id == ^slot),
        set: [
          amount_paid_derived: amount,
          amount_outstanding_derived: Decimal.sub(s.amount, amount),
          is_paid_derived: Decimal.eq?(Decimal.sub(s.amount, amount), 0)
        ]
      )
    end

    :ok
  end

  defp set_charge_paid!(charge, paid, total) do
    outstanding = Decimal.sub(total, paid)

    waived? =
      TenantRepo.one(from(c in "m_loan_charge", where: c.id == ^charge, select: c.waived))

    TenantRepo.update_all(from(c in "m_loan_charge", where: c.id == ^charge),
      set: [
        amount_paid_derived: paid,
        amount_outstanding_derived: outstanding,
        is_paid_derived: Decimal.eq?(outstanding, 0) and not waived?
      ]
    )
  end

  @doc "What each charge has paid so far, `%{loan_charge_id => amount}` (charges not yet paid are left out)."
  @spec paid_map(integer) :: %{integer => Decimal.t()}
  def paid_map(loan_id) do
    from(c in "m_loan_charge",
      where: c.loan_id == ^loan_id and c.is_active == true and c.charge_time_enum != 1,
      select: {c.id, c.amount_paid_derived}
    )
    |> TenantRepo.all()
    |> Map.new(fn {id, paid} -> {id, paid || Decimal.new(0)} end)
  end

  @doc "Records what transaction `tx_id` paid of each charge: the difference between two `paid_map`s."
  @spec record_payment!(integer, map, map) :: :ok
  def record_payment!(tx_id, before, after_paying) do
    for {charge, paid} <- Enum.sort(after_paying),
        paid_now = Decimal.sub(paid, Map.get(before, charge, Decimal.new(0))),
        Decimal.compare(paid_now, 0) == :gt do
      record_paid_by!(tx_id, charge, paid_now)
    end

    :ok
  end

  @doc "Marks every charge of the loan as paid in full (what a write-off does to them)."
  @spec mark_all_paid!(integer) :: :ok
  def mark_all_paid!(loan_id) do
    TenantRepo.update_all(
      from(c in "m_loan_charge", where: c.loan_id == ^loan_id and c.is_active == true),
      set: [is_paid_derived: true]
    )

    TenantRepo.query!(
      "UPDATE m_loan_charge SET amount_paid_derived = amount, amount_outstanding_derived = 0 WHERE loan_id = $1 AND is_active",
      [loan_id]
    )

    :ok
  end

  @doc "Records that transaction `tx_id` is about `amount` of the loan charge `loan_charge_id` (an accrual, say)."
  @spec record_paid_by!(integer, integer, Decimal.t(), integer | nil) :: :ok
  def record_paid_by!(tx_id, loan_charge_id, amount, installment \\ nil) do
    TenantRepo.insert_all("m_loan_charge_paid_by", [
      %{
        loan_transaction_id: tx_id,
        loan_charge_id: loan_charge_id,
        amount: amount,
        installment_number: installment
      }
    ])

    :ok
  end

  @doc "The installment a charge with a due date falls in: the first one due on or after the date."
  @spec installment_of(integer, Date.t() | nil) :: integer | nil
  def installment_of(_loan_id, nil), do: nil

  def installment_of(loan_id, date) do
    TenantRepo.one(
      from(r in "m_loan_repayment_schedule",
        where: r.loan_id == ^loan_id and r.duedate >= ^date,
        order_by: r.installment,
        limit: 1,
        select: r.installment
      )
    )
  end

  @doc "What has been paid of the charges due at disbursement."
  @spec paid_at_disbursement(integer) :: Decimal.t()
  def paid_at_disbursement(loan_id) do
    TenantRepo.one(
      from(c in "m_loan_charge",
        where: c.loan_id == ^loan_id and c.charge_time_enum == 1 and c.is_active == true,
        select: sum(coalesce(c.amount_paid_derived, 0))
      )
    ) || Decimal.new(0)
  end

  @doc "Removes the installment charges of the loan (before its schedule is replaced)."
  @spec clear_installment_charges!(integer) :: :ok
  def clear_installment_charges!(loan_id) do
    ids = TenantRepo.all(from(c in "m_loan_charge", where: c.loan_id == ^loan_id, select: c.id))
    TenantRepo.delete_all(from(i in "m_loan_installment_charge", where: i.loan_charge_id in ^ids))
    :ok
  end

  @doc "Deletes a charge of a loan and what it asks of each installment."
  @spec remove!(integer) :: :ok
  def remove!(charge_id) do
    TenantRepo.delete_all(
      from(i in "m_loan_installment_charge", where: i.loan_charge_id == ^charge_id)
    )

    TenantRepo.delete_all(from(c in "m_loan_charge", where: c.id == ^charge_id))
    :ok
  end

  @doc """
  Adds one charge to a loan that already has its schedule, as `%{charge:, total:, applied_to:, installments:}`
  (see `ECBLoans.Schedule.Charges`). Returns the id of the new row.
  """
  @spec add!(integer, map, struct) :: integer
  def add!(loan_id, detail, user) do
    id = insert!(loan_id, detail, user, %{amount_paid_derived: Decimal.new(0)})
    installment_charges!(loan_id, [detail], [id])
    id
  end

  @doc """
  Works the fee and penalty columns of every installment out again from the loan's charges, as Fineract's
  repayment schedule wrapper does: an installment fee in each installment, a charge on a date in the installment
  that holds the date, less what was waived or written off. An installment without a row for an installment fee
  (one added only to hold a charge) takes the flat amount.
  """
  @spec refresh_installments!(integer) :: :ok
  def refresh_installments!(loan_id) do
    charges =
      TenantRepo.all(
        from(c in "m_loan_charge",
          where: c.loan_id == ^loan_id and c.is_active == true and c.charge_time_enum != 1,
          select: %{
            id: c.id,
            time: c.charge_time_enum,
            calc: c.charge_calculation_enum,
            penalty: c.is_penalty,
            due: c.due_for_collection_as_of_date,
            amount: c.amount,
            input: c.charge_amount_or_percentage,
            waived: c.amount_waived_derived,
            off: c.amount_writtenoff_derived
          }
        )
      )

    per_installment = per_installment_amounts(loan_id)
    rows = ECBLoans.Loans.installments(loan_id)

    for r <- rows do
      mine = Enum.map(charges, &share(&1, r, rows, per_installment))

      set =
        for {penalty?, prefix} <- [{false, :fee_charges}, {true, :penalty_charges}],
            {suffix, key} <- [
              {"amount", :amount},
              {"waived_derived", :waived},
              {"writtenoff_derived", :off}
            ] do
          total =
            mine
            |> Enum.filter(&(&1.penalty == penalty?))
            |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1[key]))

          {String.to_existing_atom("#{prefix}_#{suffix}"),
           if(Decimal.eq?(total, 0), do: nil, else: total)}
        end

      TenantRepo.update_all(from(i in "m_loan_repayment_schedule", where: i.id == ^r.id),
        set: set
      )
    end

    :ok
  end

  # what a charge asks of an installment: nothing, or its amount, less what was waived and written off
  defp share(%{time: 8} = c, r, _rows, per_installment) do
    zero = Decimal.new(0)

    case Map.get(per_installment, {c.id, r.installment}) do
      nil ->
        flat = if c.calc == 1, do: c.input || zero, else: zero
        %{penalty: c.penalty, amount: flat, waived: zero, off: zero}

      row ->
        %{
          penalty: c.penalty,
          amount: row.amount,
          waived: row.waived || zero,
          off: row.off || zero
        }
    end
  end

  defp share(%{time: 2} = c, r, rows, _per_installment) do
    zero = Decimal.new(0)
    holder = Enum.find(rows, &(Date.compare(&1.due_date, c.due) != :lt))

    if holder && holder.installment == r.installment,
      do: %{penalty: c.penalty, amount: c.amount, waived: c.waived || zero, off: c.off || zero},
      else: %{penalty: c.penalty, amount: zero, waived: zero, off: zero}
  end

  defp share(c, _r, _rows, _per_installment),
    do: %{penalty: c.penalty, amount: Decimal.new(0), waived: Decimal.new(0), off: Decimal.new(0)}

  defp per_installment_amounts(loan_id) do
    from(i in "m_loan_installment_charge",
      join: c in "m_loan_charge",
      on: c.id == i.loan_charge_id,
      join: r in "m_loan_repayment_schedule",
      on: r.id == i.loan_schedule_id,
      where: c.loan_id == ^loan_id and c.is_active == true,
      select:
        {{c.id, r.installment},
         %{
           amount: i.amount,
           waived: i.amount_waived_derived,
           off: i.amount_writtenoff_derived
         }}
    )
    |> TenantRepo.all()
    |> Map.new()
  end

  defp rows(loan_id) do
    TenantRepo.all(
      from(c in "m_loan_charge",
        where: c.loan_id == ^loan_id,
        order_by: c.id,
        select: %{id: c.id}
      )
    )
  end

  defp delete_all!(loan_id) do
    ids = TenantRepo.all(from(c in "m_loan_charge", where: c.loan_id == ^loan_id, select: c.id))
    TenantRepo.delete_all(from(i in "m_loan_installment_charge", where: i.loan_charge_id in ^ids))
    TenantRepo.delete_all(from(c in "m_loan_charge", where: c.id in ^ids))
  end

  defp insert!(loan_id, detail, user, extra \\ %{}) do
    now = DateTime.utc_now()
    row = values(detail)

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_loan_charge",
        [
          Map.merge(row, %{
            loan_id: loan_id,
            submitted_on_date: ECBPlatform.BusinessDate.current(),
            amount_outstanding_derived: row.amount,
            is_paid_derived: false,
            waived: false,
            is_active: true,
            created_by: user.id,
            created_on_utc: now,
            last_modified_by: user.id,
            last_modified_on_utc: now
          })
          |> Map.merge(extra)
        ],
        returning: [:id]
      )

    id
  end

  defp update!(%{id: id}, detail) do
    row = values(detail)

    TenantRepo.update_all(from(c in "m_loan_charge", where: c.id == ^id),
      set: Map.to_list(Map.put(row, :amount_outstanding_derived, row.amount))
    )

    id
  end

  # what the schedule worked out for a charge, as the columns of its row
  defp values(%{charge: c, total: total, applied_to: applied_to}) do
    percent? = c.calc != 1

    %{
      charge_id: c.charge_id,
      is_penalty: c.penalty,
      charge_time_enum: c.time,
      due_for_collection_as_of_date: if(c.time == 2, do: c.due_date),
      charge_calculation_enum: c.calc,
      charge_payment_mode_enum: c.payment_mode,
      calculation_percentage: if(percent?, do: c.amount),
      calculation_on_amount: applied_to,
      charge_amount_or_percentage: c.amount,
      amount: ECBMoney.amount(total)
    }
  end

  # the installment fees, installment by installment
  defp installment_charges!(loan_id, details, ids) do
    schedule_ids =
      Map.new(
        TenantRepo.all(
          from(r in "m_loan_repayment_schedule",
            where: r.loan_id == ^loan_id,
            select: {r.installment, {r.id, r.duedate}}
          )
        )
      )

    TenantRepo.delete_all(from(i in "m_loan_installment_charge", where: i.loan_charge_id in ^ids))

    rows =
      for {%{charge: %{time: 8}, installments: installments}, charge_id} <-
            Enum.zip(details, ids),
          {number, money} <- installments,
          {schedule_id, due} = Map.fetch!(schedule_ids, number),
          do: %{
            loan_charge_id: charge_id,
            loan_schedule_id: schedule_id,
            due_date: due,
            amount: ECBMoney.amount(money),
            amount_outstanding_derived: ECBMoney.amount(money),
            is_paid_derived: false,
            waived: false
          }

    if rows != [], do: TenantRepo.insert_all("m_loan_installment_charge", rows)
    :ok
  end

  defp set_due_at_disbursement!(loan_id, schedule) do
    due =
      if schedule[:disbursement_fees] && ECBMoney.positive?(schedule.disbursement_fees),
        do: ECBMoney.amount(schedule.disbursement_fees)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan_id),
      set: [total_charges_due_at_disbursement_derived: due]
    )
  end
end
