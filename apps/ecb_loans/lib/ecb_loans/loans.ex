defmodule ECBLoans.Loans do
  @moduledoc """
  Loan accounts as they are read (Fineract's `LoanReadPlatformServiceImpl`): one loan with its client,
  product, fund, loan officer, purpose and the people who took each step, a page of loans, and the
  repayment schedule rows. Must run inside a tenant scope.

  A loan's status is a number (`loan_status_id`): 100 submitted and pending approval, 200 approved, 300 active,
  400 withdrawn by the applicant, 500 rejected, 600 closed (obligations met), 601 closed (written off),
  602 closed (rescheduled), 700 overpaid.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @statuses %{
    submitted: 100,
    approved: 200,
    active: 300,
    withdrawn: 400,
    rejected: 500,
    closed: 600,
    written_off: 601,
    rescheduled: 602,
    overpaid: 700
  }

  @static Path.join(:code.priv_dir(:ecb_loans), "loan_account_static.json")
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("loan")

  @external_resource Path.join(:code.priv_dir(:ecb_loans), "loan_account_static.json")

  @doc "What a loan shows that does not depend on the loan (flags that are off, lists of choices)."
  @spec static() :: map
  def static, do: @static

  @doc "The number of a status, by name."
  @spec status(atom) :: integer
  def status(name), do: Map.fetch!(@statuses, name)

  @doc "Fineract's `LoanStatusEnumData` for a status number."
  @spec status_json(integer) :: map
  def status_json(id) do
    {code, value} = status_names(id)

    %{
      "id" => id,
      "code" => code,
      "value" => value,
      "pendingApproval" => id == 100,
      "waitingForDisbursal" => id == 200,
      "active" => id == 300,
      "closedObligationsMet" => id == 600,
      "closedWrittenOff" => id == 601,
      "closedRescheduled" => id == 602,
      "closed" => id in [600, 601, 602],
      "overpaid" => id == 700
    }
  end

  defp status_names(100),
    do: {"loanStatusType.submitted.and.pending.approval", "Submitted and pending approval"}

  defp status_names(200), do: {"loanStatusType.approved", "Approved"}
  defp status_names(300), do: {"loanStatusType.active", "Active"}
  defp status_names(400), do: {"loanStatusType.withdrawn.by.client", "Withdrawn by applicant"}
  defp status_names(500), do: {"loanStatusType.rejected", "Rejected"}

  defp status_names(600),
    do: {"loanStatusType.closed.obligations.met", "Closed (obligations met)"}

  defp status_names(601), do: {"loanStatusType.closed.written.off", "Closed (written off)"}
  defp status_names(602), do: {"loanStatusType.closed.rescheduled", "Closed (rescheduled)"}
  defp status_names(700), do: {"loanStatusType.overpaid", "Overpaid"}
  defp status_names(id), do: {"loanStatusType.invalid", "Invalid (#{id})"}

  # --- reading --------------------------------------------------------------------------------

  @select """
  l.id, l.account_no, l.external_id, l.client_id, l.product_id, l.fund_id, l.loan_officer_id,
  l.loanpurpose_cv_id, l.loan_status_id, l.loan_type_enum, l.currency_code, l.currency_digits,
  l.currency_multiplesof, l.principal_amount_proposed, l.principal_amount, l.approved_principal,
  l.net_disbursal_amount, l.arrearstolerance_amount, l.nominal_interest_rate_per_period,
  l.interest_period_frequency_enum, l.annual_nominal_interest_rate, l.interest_method_enum,
  l.interest_calculated_in_period_enum, l.allow_partial_period_interest_calcualtion, l.term_frequency,
  l.term_period_frequency_enum, l.repay_every, l.repayment_period_frequency_enum, l.number_of_repayments,
  l.grace_on_principal_periods, l.grace_on_interest_periods, l.grace_interest_free_periods,
  l.grace_on_arrears_ageing, l.amortization_method_enum, l.submittedon_date, l.approvedon_date,
  l.expected_disbursedon_date, l.expected_firstrepaymenton_date, l.interest_calculated_from_date,
  l.disbursedon_date, l.expected_maturedon_date, l.maturedon_date, l.closedon_date, l.rejectedon_date,
  l.withdrawnon_date, l.writtenoffon_date, l.overpaidon_date, l.loan_transaction_strategy_code, l.loan_transaction_strategy_name,
  l.days_in_month_enum, l.days_in_year_enum, l.interest_recalculation_enabled, l.repayment_start_date_type_enum,
  l.created_by, l.approvedon_userid, l.disbursedon_userid, l.closedon_userid, l.rejectedon_userid,
  l.withdrawnon_userid, l.is_npa, l.loan_product_counter,
  l.principal_disbursed_derived, l.principal_repaid_derived, l.principal_writtenoff_derived,
  l.principal_outstanding_derived, l.interest_charged_derived, l.interest_repaid_derived,
  l.interest_waived_derived, l.interest_writtenoff_derived, l.interest_outstanding_derived,
  l.fee_charges_charged_derived, l.fee_charges_repaid_derived, l.fee_charges_waived_derived,
  l.fee_charges_writtenoff_derived, l.fee_charges_outstanding_derived, l.penalty_charges_charged_derived,
  l.penalty_charges_repaid_derived, l.penalty_charges_waived_derived, l.penalty_charges_writtenoff_derived,
  l.penalty_charges_outstanding_derived, l.total_expected_repayment_derived, l.total_repayment_derived,
  l.total_expected_costofloan_derived, l.total_costofloan_derived, l.total_waived_derived,
  l.total_writtenoff_derived, l.total_outstanding_derived, l.total_overpaid_derived, l.total_recovered_derived,
  l.total_charges_due_at_disbursement_derived, l.principal_adjustments_derived,
  c.account_no AS client_account_no, c.display_name AS client_name, c.office_id AS client_office_id,
  o.name AS office_name, o.hierarchy AS office_hierarchy,
  p.name AS product_name, p.description AS product_description,
  cur.name AS currency_name, cur.display_symbol AS currency_symbol, cur.internationalized_name_code AS currency_name_code,
  f.name AS fund_name, s.display_name AS loan_officer_name, cv.code_value AS loan_purpose_name,
  su.username AS submitted_by_username, su.firstname AS submitted_by_firstname, su.lastname AS submitted_by_lastname,
  au.username AS approved_by_username, au.firstname AS approved_by_firstname, au.lastname AS approved_by_lastname,
  du.username AS disbursed_by_username, du.firstname AS disbursed_by_firstname, du.lastname AS disbursed_by_lastname,
  cu.username AS closed_by_username, cu.firstname AS closed_by_firstname, cu.lastname AS closed_by_lastname,
  ru.username AS rejected_by_username, ru.firstname AS rejected_by_firstname, ru.lastname AS rejected_by_lastname,
  wu.username AS withdrawn_by_username, wu.firstname AS withdrawn_by_firstname, wu.lastname AS withdrawn_by_lastname
  """

  @from """
  FROM m_loan l
  JOIN m_client c ON c.id = l.client_id
  JOIN m_office o ON o.id = c.office_id
  JOIN m_product_loan p ON p.id = l.product_id
  LEFT JOIN m_currency cur ON cur.code = l.currency_code
  LEFT JOIN m_fund f ON f.id = l.fund_id
  LEFT JOIN m_staff s ON s.id = l.loan_officer_id
  LEFT JOIN m_code_value cv ON cv.id = l.loanpurpose_cv_id
  LEFT JOIN m_appuser su ON su.id = l.created_by
  LEFT JOIN m_appuser au ON au.id = l.approvedon_userid
  LEFT JOIN m_appuser du ON du.id = l.disbursedon_userid
  LEFT JOIN m_appuser cu ON cu.id = l.closedon_userid
  LEFT JOIN m_appuser ru ON ru.id = l.rejectedon_userid
  LEFT JOIN m_appuser wu ON wu.id = l.withdrawnon_userid
  """

  @orderings %{
    "id" => "l.id",
    "accountNo" => "l.account_no",
    "externalId" => "l.external_id",
    "submittedOnDate" => "l.submittedon_date",
    "status" => "l.loan_status_id"
  }

  @doc "Loan `id` as a map, or `nil`."
  @spec get(integer) :: map | nil
  def get(id), do: one("WHERE l.id = $1", [id])

  @doc "Loan `id`, or the not-found error (`error.msg.loan.id.invalid`)."
  @spec fetch!(integer) :: map
  def fetch!(id), do: get(id) || raise(not_found(id))

  @doc "The loan with the external id, or `nil`."
  @spec get_by_external_id(String.t()) :: map | nil
  def get_by_external_id(external_id), do: one("WHERE l.external_id = $1", [external_id])

  @doc "The not-found error for a loan id."
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.loan.id.invalid",
        "Loan with identifier #{id} does not exist",
        [id]
      )

  @doc "The not-found error for a loan external id."
  def not_found_by_external_id(external_id),
    do:
      ResourceNotFound.new(
        "error.msg.loan.external.id.invalid",
        "Loan with external identifier #{external_id} does not exist",
        [external_id]
      )

  @doc """
  A page of loans the user may see, as `%{total:, items:}`. Options: `:external_id`, `:account_no`,
  `:hierarchy`, `:order_by`, `:sort_order`, `:limit`, `:offset`.
  """
  @spec list(struct, keyword) :: %{total: integer, items: [map]}
  def list(user, opts \\ []) do
    pattern = ECBOrg.Offices.user_hierarchy_pattern(user)
    {criteria, params} = criteria(opts, [pattern])
    where = "WHERE o.hierarchy LIKE $1" <> Enum.map_join(criteria, "", &(" AND " <> &1))

    total =
      TenantRepo.query!("SELECT count(*) " <> @from <> where, params).rows |> hd() |> hd()

    sql = "SELECT " <> @select <> @from <> where <> order(opts) <> paging(opts)
    %{total: total, items: rows(TenantRepo.query!(sql, params))}
  end

  defp criteria(opts, params) do
    [
      {:external_id, "l.external_id = ", & &1},
      {:account_no, "l.account_no = ", & &1},
      {:hierarchy, "o.hierarchy LIKE ", &(&1 <> "%")}
    ]
    |> Enum.reduce({[], params}, fn {key, sql, convert}, {parts, params} ->
      case Keyword.get(opts, key) do
        nil ->
          {parts, params}

        value ->
          params = params ++ [convert.(value)]
          {parts ++ ["#{sql}$#{length(params)}"], params}
      end
    end)
  end

  defp order(opts) do
    case Keyword.get(opts, :order_by) do
      nil ->
        " ORDER BY l.id"

      field ->
        direction =
          if String.upcase(Keyword.get(opts, :sort_order) || "") == "DESC", do: " DESC", else: ""

        " ORDER BY " <> Map.fetch!(@orderings, field) <> direction
    end
  end

  defp paging(opts) do
    case {Keyword.get(opts, :limit), Keyword.get(opts, :offset)} do
      {nil, _} -> ""
      {limit, nil} -> " LIMIT #{limit}"
      {limit, offset} -> " LIMIT #{limit} OFFSET #{offset}"
    end
  end

  defp one(where, params) do
    sql = "SELECT " <> @select <> @from <> where
    sql |> then(&TenantRepo.query!(&1, params)) |> rows() |> List.first()
  end

  defp rows(%{columns: columns, rows: rows}) do
    names = Enum.map(columns, &String.to_atom/1)
    for row <- rows, do: names |> Enum.zip(row) |> Map.new()
  end

  @doc "The repayment schedule rows of a loan, in order, as maps."
  @spec installments(integer) :: [map]
  def installments(loan_id) do
    from(r in "m_loan_repayment_schedule",
      where: r.loan_id == ^loan_id,
      order_by: [r.installment, r.id],
      select: %{
        id: r.id,
        installment: r.installment,
        from_date: r.fromdate,
        due_date: r.duedate,
        principal: r.principal_amount,
        principal_completed: r.principal_completed_derived,
        principal_writtenoff: r.principal_writtenoff_derived,
        interest: r.interest_amount,
        interest_completed: r.interest_completed_derived,
        interest_waived: r.interest_waived_derived,
        interest_writtenoff: r.interest_writtenoff_derived,
        fee_charges: r.fee_charges_amount,
        fee_charges_completed: r.fee_charges_completed_derived,
        fee_charges_waived: r.fee_charges_waived_derived,
        fee_charges_writtenoff: r.fee_charges_writtenoff_derived,
        penalty_charges: r.penalty_charges_amount,
        penalty_charges_completed: r.penalty_charges_completed_derived,
        penalty_charges_waived: r.penalty_charges_waived_derived,
        penalty_charges_writtenoff: r.penalty_charges_writtenoff_derived,
        completed: r.completed_derived,
        obligations_met_on: r.obligations_met_on_date,
        paid_in_advance: r.total_paid_in_advance_derived,
        paid_late: r.total_paid_late_derived,
        accrual_interest: r.accrual_interest_derived
      }
    )
    |> TenantRepo.all()
  end

  @doc "The transactions of a loan, oldest first, each with its office and payment details."
  @spec transactions(integer) :: [map]
  def transactions(loan_id) do
    TenantRepo.query!(
      """
      SELECT t.id, t.loan_id, t.office_id, o.name AS office_name, t.payment_detail_id, t.is_reversed,
             t.external_id, t.transaction_type_enum, t.transaction_date, t.amount,
             t.principal_portion_derived, t.interest_portion_derived, t.fee_charges_portion_derived,
             t.penalty_charges_portion_derived, t.overpayment_portion_derived, t.unrecognized_income_portion,
             t.outstanding_loan_balance_derived, t.submitted_on_date, t.manually_adjusted_or_reversed,
             t.reversal_external_id, t.reversed_on_date,
             pd.payment_type_id, pt.value AS payment_type_name, pt.description AS payment_type_description,
             pt.is_cash_payment, pt.order_position AS payment_type_position,
             pd.account_number, pd.check_number, pd.receipt_number, pd.bank_number, pd.routing_code
      FROM m_loan_transaction t
      JOIN m_office o ON o.id = t.office_id
      LEFT JOIN m_payment_detail pd ON pd.id = t.payment_detail_id
      LEFT JOIN m_payment_type pt ON pt.id = pd.payment_type_id
      WHERE t.loan_id = $1
      ORDER BY t.transaction_date, t.id
      """,
      [loan_id]
    )
    |> rows()
  end

  @doc "One transaction of a loan, or `nil`."
  @spec transaction(integer, integer) :: map | nil
  def transaction(loan_id, id), do: loan_id |> transactions() |> Enum.find(&(&1.id == id))

  @doc "The not-found error for a loan transaction id."
  def transaction_not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.loan.transaction.id.invalid",
        "Transaction with identifier #{id} does not exist",
        [id]
      )

  @doc "The notes on a loan (and on its transactions), oldest first."
  @spec notes(integer) :: [map]
  def notes(loan_id) do
    TenantRepo.query!(
      """
      SELECT n.id, n.client_id, n.loan_id, n.loan_transaction_id, n.note_type_enum, n.note,
             n.created_by, cu.username AS created_by_username, n.created_on_utc,
             n.last_modified_by, mu.username AS modified_by_username, n.last_modified_on_utc
      FROM m_note n
      LEFT JOIN m_appuser cu ON cu.id = n.created_by
      LEFT JOIN m_appuser mu ON mu.id = n.last_modified_by
      WHERE n.loan_id = $1 ORDER BY n.id
      """,
      [loan_id]
    )
    |> rows()
  end

  @doc "Adds a note to a loan; a blank note adds nothing."
  @spec add_note(integer, integer | nil, String.t() | nil, integer, integer | nil) :: :ok
  def add_note(loan_id, client_id, note, user_id, transaction_id \\ nil)
  def add_note(_loan_id, _client_id, nil, _user_id, _tx), do: :ok

  def add_note(loan_id, client_id, note, user_id, transaction_id) do
    if String.trim(note) == "" do
      :ok
    else
      now = DateTime.utc_now()

      TenantRepo.insert_all("m_note", [
        %{
          loan_id: loan_id,
          client_id: client_id,
          loan_transaction_id: transaction_id,
          note_type_enum: if(transaction_id, do: 300, else: 200),
          note: note,
          created_by: user_id,
          created_on_utc: now,
          last_modified_by: user_id,
          last_modified_on_utc: now
        }
      ])

      :ok
    end
  end
end
