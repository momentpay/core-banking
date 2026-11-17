defmodule ECBLoans.Loans.Arrears do
  @moduledoc """
  The arrears of a loan, kept in `m_loan_arrears_aging` as Fineract keeps them (`LoanArrearsAgingServiceImpl`,
  `LoanArrearsAgeingUpdateHandler`): what is overdue by principal, interest, fees and penalties, and since
  when. A loan has a row only while something is overdue.

  The row is brought up to date when the loan changes (`update!/1`, called when its derived totals are worked out
  again) and for every active loan by the job "Update Loan Arrears Ageing" (`LA_ARAG`, `update_all!/0`). A loan
  whose installment falls due is therefore not in arrears until the job runs or something happens to the loan,
  as in Fineract.

  The two differ as they do in Fineract: the job leaves out the days of the loan's grace on arrears ageing, a
  change to the loan does not. Arrears worked out from the original schedule (interest recalculation) are not
  supported.
  """
  import Ecto.Query

  alias ECBPlatform.{BusinessDate, TenantRepo}

  @columns ~w(principal_overdue_derived interest_overdue_derived fee_charges_overdue_derived
              penalty_charges_overdue_derived total_overdue_derived overdue_since_date_derived)a

  # what an installment still owes, by kind (the schedule columns; the unpaid part is what remains)
  @principal "COALESCE(s.principal_amount, 0) - COALESCE(s.principal_completed_derived, 0) - COALESCE(s.principal_writtenoff_derived, 0)"
  @interest "COALESCE(s.interest_amount, 0) - COALESCE(s.interest_writtenoff_derived, 0) - COALESCE(s.interest_waived_derived, 0) - COALESCE(s.interest_completed_derived, 0)"
  @fees "COALESCE(s.fee_charges_amount, 0) - COALESCE(s.fee_charges_writtenoff_derived, 0) - COALESCE(s.fee_charges_waived_derived, 0) - COALESCE(s.fee_charges_completed_derived, 0)"
  @penalties "COALESCE(s.penalty_charges_amount, 0) - COALESCE(s.penalty_charges_writtenoff_derived, 0) - COALESCE(s.penalty_charges_waived_derived, 0) - COALESCE(s.penalty_charges_completed_derived, 0)"

  @doc """
  The arrears recorded for loan `loan_id`: a map with `principal`, `interest`, `fees`, `penalties`, `total`
  and `since`, or `nil` when the loan has none.
  """
  @spec get(integer) :: map | nil
  def get(loan_id) do
    TenantRepo.one(
      from(a in "m_loan_arrears_aging",
        where: a.loan_id == ^loan_id,
        select: %{
          principal: a.principal_overdue_derived,
          interest: a.interest_overdue_derived,
          fees: a.fee_charges_overdue_derived,
          penalties: a.penalty_charges_overdue_derived,
          total: a.total_overdue_derived,
          since: a.overdue_since_date_derived
        }
      )
    )
  end

  @doc """
  Works the arrears of loan `loan_id` out again from its schedule and the business date: every installment due
  before the business date and not paid counts, and the loan is in arrears since the earliest of them. The row is
  kept in step: written when something is overdue, removed when not.
  """
  @spec update!(integer) :: :ok
  def update!(loan_id) do
    # only a loan that is paid out and not closed can be in arrears (undoing a disbursal clears them)
    values = if active?(loan_id), do: overdue(loan_id, BusinessDate.current(), 0)

    if values, do: write!(loan_id, values), else: remove!(loan_id)
  end

  defp active?(loan_id) do
    TenantRepo.one(from(l in "m_loan", where: l.id == ^loan_id, select: l.loan_status_id)) == 300
  end

  @doc """
  The job: replaces the arrears of every active loan, counting only the installments that fell due before the
  business date less the loan's grace on arrears ageing.
  """
  @spec update_all!() :: :ok
  def update_all! do
    till = BusinessDate.current()

    TenantRepo.transaction(fn ->
      TenantRepo.query!("DELETE FROM m_loan_arrears_aging")

      for [loan_id] <-
            TenantRepo.query!("SELECT id FROM m_loan WHERE loan_status_id = 300 ORDER BY id").rows,
          values = overdue(loan_id, till, grace(loan_id)),
          do: write!(loan_id, values)
    end)

    :ok
  end

  defp grace(loan_id) do
    TenantRepo.one(
      from(l in "m_loan", where: l.id == ^loan_id, select: coalesce(l.grace_on_arrears_ageing, 0))
    )
  end

  # the unpaid installments due before `till` less `grace` days, summed; `nil` when nothing is overdue
  defp overdue(loan_id, till, grace) do
    %{rows: [[principal, interest, fees, penalties, since]]} =
      TenantRepo.query!(
        """
        SELECT sum(#{@principal}), sum(#{@interest}), sum(#{@fees}), sum(#{@penalties}), min(s.duedate)
          FROM m_loan_repayment_schedule s
         WHERE s.loan_id = $1 AND s.completed_derived IS NOT TRUE AND s.duedate < $2::date - $3::int
        """,
        [loan_id, till, grace]
      )

    if since do
      total = principal |> Decimal.add(interest) |> Decimal.add(fees) |> Decimal.add(penalties)

      if Decimal.compare(total, 0) == :gt,
        do: %{
          principal_overdue_derived: principal,
          interest_overdue_derived: interest,
          fee_charges_overdue_derived: fees,
          penalty_charges_overdue_derived: penalties,
          total_overdue_derived: total,
          overdue_since_date_derived: since
        }
    end
  end

  defp write!(loan_id, values) do
    row = Map.take(values, @columns)

    case TenantRepo.update_all(from(a in "m_loan_arrears_aging", where: a.loan_id == ^loan_id),
           set: Map.to_list(row)
         ) do
      {1, _} ->
        :ok

      {0, _} ->
        TenantRepo.insert_all("m_loan_arrears_aging", [Map.put(row, :loan_id, loan_id)])
        :ok
    end
  end

  defp remove!(loan_id) do
    TenantRepo.delete_all(from(a in "m_loan_arrears_aging", where: a.loan_id == ^loan_id))
    :ok
  end
end
