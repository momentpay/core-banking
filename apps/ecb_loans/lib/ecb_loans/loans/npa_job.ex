defmodule ECBLoans.Loans.NpaJob do
  @moduledoc """
  The job "Update Non Performing Assets" (`LA_UNPA`), after Fineract's `UpdateNpaTasklet`: marks the active loans
  whose oldest overdue installment fell due more than the days their product allows (`overdue_days_for_npa`) as non
  performing (`is_npa`), and takes the mark off those that are no longer overdue.

  It works from the arrears the loan has (`m_loan_arrears_aging`, see `ECBLoans.Loans.Arrears`) and so sees only what
  the last change to the loan or the arrears job (`LA_ARAG`) left there. A product that keeps its loans non performing
  until the arrears are paid in full (`accountMovesOutOfNPAOnlyOnArrearsCompletion`) lets go of them only when they
  have no arrears at all.
  """
  alias ECBPlatform.{BusinessDate, TenantRepo}

  # Fineract's own statements, as they are written there: the first has no parentheses around the status test, so a
  # product that moves loans out of NPA only on completion is not held to the active status
  @reset """
  UPDATE m_loan SET is_npa = false, last_modified_by = $1, last_modified_on_utc = $2
    FROM (SELECT loan2.id FROM m_loan loan2
            LEFT JOIN m_loan_arrears_aging laa ON laa.loan_id = loan2.id
           INNER JOIN m_product_loan mpl ON mpl.id = loan2.product_id AND mpl.overdue_days_for_npa IS NOT NULL
           WHERE loan2.loan_status_id = 300 AND mpl.account_moves_out_of_npa_only_on_arrears_completion = false
              OR (mpl.account_moves_out_of_npa_only_on_arrears_completion = true
                  AND laa.overdue_since_date_derived IS NULL)) sl
   WHERE m_loan.id = sl.id
  """

  @mark """
  UPDATE m_loan SET is_npa = true, last_modified_by = $1, last_modified_on_utc = $2
    FROM (SELECT loan.id FROM m_loan_arrears_aging laa
           INNER JOIN m_loan loan ON laa.loan_id = loan.id
           INNER JOIN m_product_loan mpl ON mpl.id = loan.product_id AND mpl.overdue_days_for_npa IS NOT NULL
           WHERE loan.loan_status_id = 300
             AND laa.overdue_since_date_derived < ($3::date - COALESCE(mpl.overdue_days_for_npa, 0))
           GROUP BY loan.id) sl
   WHERE m_loan.id = sl.id
  """

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    now = DateTime.utc_now()
    TenantRepo.query!(@reset, [user.id, now])
    TenantRepo.query!(@mark, [user.id, now, BusinessDate.current()])
    :ok
  end
end
