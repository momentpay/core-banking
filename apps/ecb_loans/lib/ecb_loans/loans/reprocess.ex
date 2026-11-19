defmodule ECBLoans.Loans.Reprocess do
  @moduledoc """
  Working a loan's repayments and waivers out again, as Fineract's `reprocessTransactions` does.

  What a repayment pays depends on what was paid before it, so taking back a repayment, adding one dated before
  others, or changing what a loan owes changes what each later repayment pays. The installments are cleared
  and every repayment and waiver still standing is applied again in order of date (then of making). One that
  now pays something different is replaced: a new transaction with the same date and amount and its new
  portions takes its place, its entries are posted, and the entries of the old one are reversed (the old one no
  longer counts and is not shown). One that pays the same stays as it is.

  A repayment that is new (`new:`) takes its place in the order and is saved last, after the ones it replaced.
  A loan that has been written off is not worked out again.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{ChargeRows, Corrections, Derived, Disburse, Journal, Repay}
  alias ECBPlatform.{BusinessDate, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @repayment 2
  @waive_interest 4
  # what is applied again: repayments (and the kinds that are paid like them) and waivers
  @replayed [2, 21, 22, 23, 8, 4]

  @doc """
  Whether a transaction on `date` would be before one the loan already has, so that the ones after it must be
  worked out again.
  """
  @spec needed?(integer, Date.t()) :: boolean
  def needed?(loan_id, date) do
    TenantRepo.exists?(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and not t.is_reversed and
            t.transaction_type_enum in ^@replayed and
            t.transaction_date > ^date
      )
    )
  end

  @doc "Whether the loan has repayments or waivers standing, which `run!/3` would apply again."
  @spec any?(integer) :: boolean
  def any?(loan_id) do
    TenantRepo.exists?(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and not t.is_reversed and t.transaction_type_enum in ^@replayed
      )
    )
  end

  @doc """
  Applies the loan's repayments and waivers again. With `new:` (`%{date, amount, payment_detail_id,
  external_id}`) a repayment not yet made is included; returns the id of its transaction, or `nil`.
  """
  @spec run!(struct, integer, keyword) :: integer | nil
  def run!(user, loan_id, opts \\ []) do
    loan = Loans.fetch!(loan_id)
    check_supported!(loan)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    reset!(loan_id)

    {ordered, pending, done_on} = replay_all(user, loan, product, opts)

    new_id =
      save_new!(user, loan, product, pending) || Enum.find_value(ordered, & &1[:reserved]) ||
        Process.delete({__MODULE__, :made})

    post_reserved!(user, loan, product, opts)
    ChargeRows.sync_paid!(loan_id)
    Derived.refresh!(loan_id, user)
    last = ordered |> List.last() |> then(&(&1 && &1.date))
    clear_closing!(loan_id)

    if last,
      do: Repay.after_repayment!(user, Loans.fetch!(loan_id), done_on || last, Decimal.new(0))

    new_id
  end

  # the repayments and waivers standing, with a new repayment among them, in their order, each one worked out
  defp replay_all(user, loan, product, opts) do
    existing = for t <- standing(loan.id), do: Map.merge(t, %{kind: :existing})

    new =
      if opts[:new],
        do: [reserve(user, loan, Map.merge(opts[:new], %{kind: :new}), opts)],
        else: []

    ordered = Enum.sort_by(existing ++ new, &{Date.to_gregorian_days(&1.date), order(&1)})

    {pending, _principal, done_on} =
      Enum.reduce(ordered, {nil, Decimal.new(0), nil}, fn tx, {pending, principal, done_on} ->
        {pending, principal} = replay(user, loan, product, tx, principal, pending, opts)
        {pending, principal, done_on || if(all_paid?(loan.id), do: tx.date)}
      end)

    {ordered, pending, done_on}
  end

  # the day the loan was settled is worked out again
  defp clear_closing!(loan_id),
    do:
      TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan_id),
        set: [closedon_date: nil, overpaidon_date: nil]
      )

  defp all_paid?(loan_id), do: Enum.all?(Loans.installments(loan_id), &(&1.completed == true))

  # a repayment that takes the place of one just taken back is saved first: its transaction is made now and filled in
  # when its turn comes
  defp reserve(user, loan, %{kind: :new} = tx, opts) do
    if opts[:first] do
      id = Disburse.insert_transaction!(user, loan, Map.merge(%{type: @repayment}, tx))
      Map.put(tx, :reserved, id)
    else
      tx
    end
  end

  # a new transaction goes after the others of its day
  defp order(%{kind: :new}), do: 1_000_000_000_000
  defp order(%{id: id}), do: id

  defp check_supported!(loan) do
    if loan.loan_status_id == Loans.status(:written_off) do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Working the repayments of a loan that is written off out again is not supported yet by E-CoreBank",
        args: ["transactionId"]
    end
  end

  defp standing(loan_id) do
    TenantRepo.all(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and not t.is_reversed and
            t.transaction_type_enum in ^@replayed,
        select: %{
          id: t.id,
          type: t.transaction_type_enum,
          date: t.transaction_date,
          amount: t.amount,
          principal: t.principal_portion_derived,
          interest: t.interest_portion_derived,
          fees: t.fee_charges_portion_derived,
          penalties: t.penalty_charges_portion_derived,
          overpayment: t.overpayment_portion_derived,
          payment_detail_id: t.payment_detail_id,
          external_id: t.external_id
        }
      )
    )
  end

  # the installments as if nothing had been paid or waived
  defp reset!(loan_id) do
    TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.loan_id == ^loan_id),
      set: [
        principal_completed_derived: nil,
        interest_completed_derived: nil,
        fee_charges_completed_derived: nil,
        penalty_charges_completed_derived: nil,
        interest_waived_derived: nil,
        principal_writtenoff_derived: nil,
        interest_writtenoff_derived: nil,
        fee_charges_writtenoff_derived: nil,
        penalty_charges_writtenoff_derived: nil,
        completed_derived: false,
        obligations_met_on_date: nil,
        total_paid_in_advance_derived: nil,
        total_paid_late_derived: nil
      ]
    )

    tx_ids =
      TenantRepo.all(from(t in "m_loan_transaction", where: t.loan_id == ^loan_id, select: t.id))

    TenantRepo.delete_all(
      from(m in "m_loan_transaction_repayment_schedule_mapping",
        where: m.loan_transaction_id in ^tx_ids
      )
    )
  end

  # --- one transaction -------------------------------------------------------------------------------------

  # a waiver not yet made is made at its turn
  defp replay(
         user,
         loan,
         product,
         %{type: @waive_interest, kind: :new} = tx,
         principal,
         pending,
         _opts
       ) do
    rows = Loans.installments(loan.id)
    balance = Decimal.sub(loan.principal_amount, principal)

    new = %{
      type: @waive_interest,
      date: tx.date,
      amount: tx.amount,
      interest: nil_zero(Decimal.sub(tx.amount, tx[:unrecognized] || 0)),
      unrecognized: tx[:unrecognized],
      balance: balance
    }

    id = Disburse.insert_transaction!(user, loan, new)
    Corrections.apply_waiver!(id, rows, tx.date, tx.amount)
    Journal.waive_interest!(user, loan, product, Map.put(new, :id, id))
    Process.put({__MODULE__, :made}, id)
    {pending, principal}
  end

  defp replay(user, loan, product, %{type: @waive_interest} = tx, principal, pending, _opts) do
    rows = Loans.installments(loan.id)
    actual = Corrections.waivable(rows, tx.amount)
    balance = Decimal.sub(loan.principal_amount, principal)

    if Decimal.eq?(actual, tx.amount) do
      TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
        set: [outstanding_loan_balance_derived: balance]
      )

      Corrections.apply_waiver!(tx.id, rows, tx.date, tx.amount)
    else
      replace_waiver(user, loan, product, tx, rows, actual, balance)
    end

    {pending, principal}
  end

  defp replay(user, loan, product, tx, principal, pending, opts) do
    rows = Loans.installments(loan.id)
    {updates, left, portions} = Repay.allocate(rows, tx.date, tx.amount)
    paid = Decimal.add(principal, portions.principal)

    now = %{
      principal: nil_zero(portions.principal),
      interest: nil_zero(portions.interest),
      fees: nil_zero(portions.fees),
      penalties: nil_zero(portions.penalties),
      overpayment: nil_zero(left)
    }

    balance = Decimal.sub(loan.principal_amount, paid)

    cond do
      tx.kind == :new and tx[:reserved] ->
        Repay.update_installments!(updates, user)
        fill_reserved!(user, loan, product, tx, now, balance, updates, opts)
        ChargeRows.sync_paid!(loan.id)
        {pending, paid}

      tx.kind == :new ->
        # the new repayment is saved after the others, but takes its place in what they find paid
        Repay.update_installments!(updates, user)
        ChargeRows.sync_paid!(loan.id)
        {%{tx: tx, now: now, updates: updates, balance: balance}, paid}

      true ->
        before_paid = ChargeRows.paid_map(loan.id)
        tx_id = tx_for(user, loan, product, tx, now, balance)
        Repay.save_installments!(updates, tx_id, user)
        after_paid = ChargeRows.sync_paid!(loan.id)
        if tx_id != tx.id, do: ChargeRows.record_payment!(tx_id, before_paid, after_paid)
        {pending, paid}
    end
  end

  # the reserved transaction gets what it pays, its mapping and its entries; the transaction it replaces is reversed
  defp fill_reserved!(user, loan, product, tx, now, balance, updates, opts) do
    set =
      for {key, column} <- [
            principal: :principal_portion_derived,
            interest: :interest_portion_derived,
            fees: :fee_charges_portion_derived,
            penalties: :penalty_charges_portion_derived,
            overpayment: :overpayment_portion_derived
          ],
          do: {column, Map.fetch!(now, key)}

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.reserved),
      set: [{:outstanding_loan_balance_derived, balance} | set]
    )

    Repay.insert_mappings!(updates, tx.reserved)
    full = Map.merge(%{type: @repayment, balance: balance}, Map.merge(tx, now))
    # its entries are posted once the others have been worked out
    Process.put({__MODULE__, :reserved}, journal(full, tx.reserved))
    _ = {user, loan, product, opts}
    :ok
  end

  defp post_reserved!(user, loan, product, opts) do
    case Process.delete({__MODULE__, :reserved}) do
      nil ->
        :ok

      full ->
        Journal.repayment!(user, loan, product, full)

        if old = opts[:reverse],
          do: Journal.reverse!(user, loan, old.id, old.transaction_date)
    end
  end

  # a waiver that now waives less is replaced by one of what it does waive
  defp replace_waiver(user, loan, product, tx, rows, actual, balance) do
    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
      set: [
        is_reversed: true,
        reversed_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    new = %{
      type: @waive_interest,
      date: tx.date,
      amount: actual,
      interest: nil_zero(actual),
      balance: balance
    }

    id = Disburse.insert_transaction!(user, loan, new)
    relate!(user, id, tx.id)
    Corrections.apply_waiver!(id, rows, tx.date, actual)
    Journal.waive_interest!(user, loan, product, Map.put(new, :id, id))
    Journal.reverse!(user, loan, tx.id, tx.date)
    id
  end

  defp save_new!(_user, _loan, _product, nil), do: nil

  defp save_new!(user, loan, product, %{tx: tx, now: now, updates: updates, balance: balance}) do
    id = tx_for(user, loan, product, tx, now, balance)
    Repay.insert_mappings!(updates, id)
    id
  end

  # the transaction to put the allocation on: the same one when it pays what it paid, else a new one in its place
  defp tx_for(user, loan, product, %{kind: :existing} = tx, now, balance) do
    if same?(tx, now) do
      TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
        set: [outstanding_loan_balance_derived: balance]
      )

      tx.id
    else
      replace(user, loan, product, tx, now, balance)
    end
  end

  defp tx_for(user, loan, product, %{kind: :new} = tx, now, balance) do
    full = Map.merge(%{type: @repayment, balance: balance}, Map.merge(tx, now))
    id = Disburse.insert_transaction!(user, loan, full)
    Journal.repayment!(user, loan, product, journal(full, id))
    id
  end

  defp same?(tx, now) do
    Enum.all?(~w(principal interest fees penalties overpayment)a, fn key ->
      equal?(Map.get(tx, key), Map.get(now, key))
    end)
  end

  defp equal?(a, b), do: Decimal.eq?(a || 0, b || 0)

  defp replace(user, loan, product, tx, now, balance) do
    # the new transaction takes the old one's external id, which the old one gives up
    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
      set: [
        is_reversed: true,
        external_id: nil,
        reversed_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    full =
      Map.merge(
        %{type: tx.type, date: tx.date, amount: tx.amount, balance: balance},
        Map.merge(Map.take(tx, [:payment_detail_id, :external_id]), now)
      )

    id = Disburse.insert_transaction!(user, loan, full)
    relate!(user, id, tx.id)
    Journal.repayment!(user, loan, product, journal(full, id))
    Journal.reverse!(user, loan, tx.id, tx.date)
    id
  end

  # the new transaction replays the old one, and whatever the old one replayed
  defp relate!(user, new_id, old_id) do
    now = DateTime.utc_now()
    earlier = Enum.map(Loans.relations(old_id), & &1.to)

    rows =
      for target <- [old_id | earlier] do
        %{
          from_loan_transaction_id: new_id,
          to_loan_transaction_id: target,
          relation_type_enum: 3,
          created_by: user.id,
          created_on_utc: now,
          last_modified_by: user.id,
          last_modified_on_utc: now
        }
      end

    TenantRepo.insert_all("m_loan_transaction_relation", rows)
  end

  # the transaction as the journal wants it
  defp journal(tx, id) do
    Map.merge(
      %{principal: nil, interest: nil, fees: nil, penalties: nil, overpayment: nil},
      Map.put(tx, :id, id)
    )
  end

  defp nil_zero(d), do: if(Decimal.eq?(d, 0), do: nil, else: d)
end
