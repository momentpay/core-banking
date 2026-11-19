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

  @template_static Path.join(:code.priv_dir(:ecb_loans), "loan_template_static.json")
                   |> File.read!()
                   |> Jason.decode!()

  @external_resource Path.join(:code.priv_dir(:ecb_loans), "loan_template_static.json")

  @doc "The lists of choices the template for a new loan carries, and the names a product offers in its lookup."
  @spec template_static() :: map
  def template_static, do: @template_static

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

  defp status_names(602),
    do: {"loanStatusType.closed.reschedule.outstanding.amount", "Closed (rescheduled)"}

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
  l.disbursedon_date, l.expected_maturedon_date, l.maturedon_date, l.closedon_date, l.accrued_till, l.rejectedon_date,
  l.withdrawnon_date, l.writtenoffon_date, l.overpaidon_date, l.loan_transaction_strategy_code, l.loan_transaction_strategy_name,
  l.days_in_month_enum, l.days_in_year_enum, l.interest_recalculation_enabled, l.repayment_start_date_type_enum,
  l.created_by, l.approvedon_userid, l.disbursedon_userid, l.closedon_userid, l.rejectedon_userid,
  l.withdrawnon_userid, l.is_npa, l.loan_product_counter, l.is_charged_off, l.charged_off_on_date, l.loan_sub_status_id,
  l.charge_off_reason_cv_id, l.charged_off_by_userid, l.rescheduledon_date,
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
  p.allow_multiple_disbursals AS multi_disburse, p.disallow_expected_disbursements AS disallow_expected_disbursements,
  l.max_outstanding_loan_balance,
  cur.name AS currency_name, cur.display_symbol AS currency_symbol, cur.internationalized_name_code AS currency_name_code,
  f.name AS fund_name, s.display_name AS loan_officer_name, cv.code_value AS loan_purpose_name,
  su.username AS submitted_by_username, su.firstname AS submitted_by_firstname, su.lastname AS submitted_by_lastname,
  au.username AS approved_by_username, au.firstname AS approved_by_firstname, au.lastname AS approved_by_lastname,
  du.username AS disbursed_by_username, du.firstname AS disbursed_by_firstname, du.lastname AS disbursed_by_lastname,
  cu.username AS closed_by_username, cu.firstname AS closed_by_firstname, cu.lastname AS closed_by_lastname,
  ru.username AS rejected_by_username, ru.firstname AS rejected_by_firstname, ru.lastname AS rejected_by_lastname,
  wu.username AS withdrawn_by_username, wu.firstname AS withdrawn_by_firstname, wu.lastname AS withdrawn_by_lastname,
  fu.username AS charged_off_by_username, fu.firstname AS charged_off_by_firstname, fu.lastname AS charged_off_by_lastname,
  fcv.code_value AS charge_off_reason
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
  LEFT JOIN m_appuser fu ON fu.id = l.charged_off_by_userid
  LEFT JOIN m_code_value fcv ON fcv.id = l.charge_off_reason_cv_id
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

  @doc """
  The number of installments a loan was planned with and has now, as Fineract counts them for `actualNoTerm`: those
  that are not additional (an installment made for a charge or penalty past the last one is) nor a down payment.
  """
  @spec actual_term(integer) :: non_neg_integer
  def actual_term(loan_id) do
    TenantRepo.aggregate(
      from(r in "m_loan_repayment_schedule",
        where: r.loan_id == ^loan_id and not r.is_additional and not r.is_down_payment
      ),
      :count
    )
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
        accrual_interest: r.accrual_interest_derived,
        accrual_fee: r.accrual_fee_charges_derived,
        accrual_penalty: r.accrual_penalty_charges_derived
      }
    )
    |> TenantRepo.all()
  end

  @doc "The charges of a loan, in the order they were made."
  @spec charges(integer) :: [map]
  def charges(loan_id), do: loan_id |> charge_query() |> TenantRepo.all()

  @doc "One charge of the loan (active or not), or `nil`."
  @spec charge(integer, integer) :: map | nil
  def charge(loan_id, id) do
    loan_id |> charge_query(false) |> where([c], c.id == ^id) |> TenantRepo.one()
  end

  @doc "What a charge asks of each installment, as `[%{installment, due_date, amount, outstanding, waived_amount, paid, waived}]`."
  @spec installment_charges(integer) :: [map]
  def installment_charges(charge_id) do
    from(i in "m_loan_installment_charge",
      join: r in "m_loan_repayment_schedule",
      on: r.id == i.loan_schedule_id,
      where: i.loan_charge_id == ^charge_id,
      order_by: r.installment,
      select: %{
        id: i.id,
        installment: r.installment,
        due_date: r.duedate,
        amount: i.amount,
        outstanding: i.amount_outstanding_derived,
        paid_amount: i.amount_paid_derived,
        waived_amount: i.amount_waived_derived,
        paid: i.is_paid_derived,
        waived: i.waived
      }
    )
    |> TenantRepo.all()
  end

  defp charge_query(loan_id, active_only \\ true) do
    from(c in "m_loan_charge",
      join: mc in "m_charge",
      on: mc.id == c.charge_id,
      where: c.loan_id == ^loan_id and (c.is_active == true or ^(!active_only)),
      order_by: c.id,
      select: %{
        id: c.id,
        loan_id: c.loan_id,
        charge_id: c.charge_id,
        name: mc.name,
        penalty: c.is_penalty,
        time: c.charge_time_enum,
        due_date: c.due_for_collection_as_of_date,
        calc: c.charge_calculation_enum,
        payment_mode: c.charge_payment_mode_enum,
        percentage: c.calculation_percentage,
        applied_to: c.calculation_on_amount,
        amount_or_percentage: c.charge_amount_or_percentage,
        amount: c.amount,
        paid: c.amount_paid_derived,
        waived_amount: c.amount_waived_derived,
        written_off: c.amount_writtenoff_derived,
        outstanding: c.amount_outstanding_derived,
        is_paid: c.is_paid_derived,
        waived: c.waived,
        submitted_on: c.submitted_on_date
      }
    )
  end

  @doc "The charges a transaction paid: `[%{loan_charge_id, charge_id, name, amount}]`."
  @spec paid_by(integer) :: [map]
  def paid_by(transaction_id) do
    from(p in "m_loan_charge_paid_by",
      join: lc in "m_loan_charge",
      on: lc.id == p.loan_charge_id,
      join: c in "m_charge",
      on: c.id == lc.charge_id,
      where: p.loan_transaction_id == ^transaction_id,
      order_by: p.loan_charge_id,
      select: %{
        id: p.id,
        loan_charge_id: p.loan_charge_id,
        charge_id: lc.charge_id,
        name: c.name,
        amount: p.amount,
        installment: p.installment_number
      }
    )
    |> TenantRepo.all()
  end

  @doc "What a transaction replays: `[%{to: old transaction id, type: enum}]`."
  @spec relations(integer) :: [map]
  def relations(transaction_id) do
    from(r in "m_loan_transaction_relation",
      where: r.from_loan_transaction_id == ^transaction_id,
      order_by: r.id,
      select: %{to: r.to_loan_transaction_id, type: r.relation_type_enum}
    )
    |> TenantRepo.all()
  end

  @doc "The transactions of a loan, oldest first, each with its office and payment details."
  @spec transactions(integer) :: [map]
  def transactions(loan_id) do
    loan_id |> transaction_rows("t.transaction_date, t.id", nil) |> rows()
  end

  @transaction_select """
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
  """

  defp transaction_rows(loan_id, order, nil),
    do: TenantRepo.query!(@transaction_select <> "ORDER BY " <> order, [loan_id])

  defp transaction_rows(loan_id, order, {limit, offset}),
    do:
      TenantRepo.query!(
        @transaction_select <> "ORDER BY " <> order <> " LIMIT $2 OFFSET $3",
        [loan_id, limit, offset]
      )

  # the sort properties Fineract's `LoanTransaction` entity has that are built, and the column each is
  @sort_columns %{
    "id" => "t.id",
    "amount" => "t.amount",
    "dateOf" => "t.transaction_date",
    "typeOf" => "t.transaction_type_enum",
    "externalId" => "t.external_id",
    "principalPortion" => "t.principal_portion_derived",
    "interestPortion" => "t.interest_portion_derived",
    "feeChargesPortion" => "t.fee_charges_portion_derived",
    "penaltyChargesPortion" => "t.penalty_charges_portion_derived",
    "overPaymentPortion" => "t.overpayment_portion_derived",
    "outstandingLoanBalance" => "t.outstanding_loan_balance_derived"
  }

  @doc "The properties the transactions of a loan can be sorted by."
  @spec transaction_sort_properties() :: [String.t()]
  def transaction_sort_properties, do: Map.keys(@sort_columns)

  @doc """
  A page of the transactions of a loan, as `%{total:, items:}`. `sort` is a list of `{property, :asc | :desc}`
  (see `transaction_sort_properties/0`); ties, and a list without sort, come in order of id.
  """
  @spec transactions_page(integer, non_neg_integer, pos_integer, [{String.t(), :asc | :desc}]) ::
          %{total: non_neg_integer, items: [map]}
  def transactions_page(loan_id, page, size, sort) do
    order =
      sort
      |> Enum.map(fn {property, direction} ->
        Map.fetch!(@sort_columns, property) <> if(direction == :desc, do: " DESC", else: " ASC")
      end)
      |> Kernel.++(["t.id"])
      |> Enum.join(", ")

    [[total]] =
      TenantRepo.query!("SELECT count(*) FROM m_loan_transaction WHERE loan_id = $1", [loan_id]).rows

    %{
      total: total,
      items: loan_id |> transaction_rows(order, {size, page * size}) |> rows()
    }
  end

  @doc "One transaction of a loan, or `nil`."
  @spec transaction(integer, integer) :: map | nil
  def transaction(loan_id, id), do: loan_id |> transactions() |> Enum.find(&(&1.id == id))

  @doc "The transaction of a loan with the external id, or `nil`."
  @spec transaction_by_external_id(integer, String.t()) :: map | nil
  def transaction_by_external_id(loan_id, external_id),
    do: loan_id |> transactions() |> Enum.find(&(&1.external_id == external_id))

  @doc "The not-found error for a loan transaction external id."
  def transaction_not_found_by_external_id(external_id),
    do:
      ResourceNotFound.new(
        "error.msg.loan.transaction.external.id.invalid",
        "Transaction with external identifier #{external_id} does not exist",
        [external_id]
      )

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
