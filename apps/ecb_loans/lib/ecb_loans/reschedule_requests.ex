defmodule ECBLoans.RescheduleRequests do
  @moduledoc """
  Requests to reschedule a loan (`m_loan_reschedule_request`), after Fineract's `RescheduleLoansApiResource`,
  `LoanRescheduleRequestWritePlatformServiceImpl` and `LoanRescheduleRequestDataValidatorImpl` for loans on the
  cumulative schedule.

  A request names a date on which an installment falls due (`rescheduleFromDate`) and what to change from there:
  a new due date (`adjustedDueDate`), a new interest rate (`newInterestRate`), a grace on principal or on interest
  (`graceOnPrincipal`, `graceOnInterest`) or extra installments (`extraTerms`). Each is stored as a *term
  variation* (`m_loan_term_variations`, not active until the request is approved). Approving the request
  (`ECBLoans.Loans.Reschedule`) makes the schedule again from the date with the variations; rejecting it only ends
  the request.

  Refused as not supported yet: a fixed installment amount over a span of dates (`emi` with `endDate`), a loan with
  charges, on accrual accounting (periodic or upfront), with interest recalculation, an interest rate of zero, or
  one that has been rescheduled already.
  """
  import Ecto.Query

  alias ECBLoans.{LoanProducts, Loans}
  alias ECBOrg.Codes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DataIntegrity, DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Json, Params, TenantRepo, Validation}

  @resource "rescheduleloan"

  @pending 100
  @approved 200
  @rejected 500

  # Fineract's `LoanTermVariationType`
  @due_date 4
  @grace_on_interest 7
  @grace_on_principal 8
  @extend_repayment_period 9
  @interest_rate_from_installment 10

  @create_params ~w(locale dateFormat graceOnPrincipal recurringMoratoriumOnPrincipalPeriods graceOnInterest
                    extraTerms rescheduleFromDate newInterestRate rescheduleReasonId rescheduleReasonComment
                    submittedOnDate loanId adjustedDueDate recalculateInterest endDate emi)
  @approve_params ~w(locale dateFormat approvedOnDate)
  @reject_params ~w(locale dateFormat rejectedOnDate)

  @doc "The status numbers: pending approval, approved, rejected."
  def status(:pending), do: @pending
  def status(:approved), do: @approved
  def status(:rejected), do: @rejected

  # --- reads --------------------------------------------------------------------------------------

  @doc """
  The requests, as the list answers them. `command` is `all`, `pending`, `approve` or `reject` (Fineract looks for
  rejected requests with status 300 and so finds none), `loan_id` narrows them to one loan.
  """
  @spec list(String.t() | nil, integer | nil) :: [map]
  def list(command, loan_id) do
    {filters, params} =
      case command do
        c when c in [nil, "", "all"] -> {[], []}
        "pending" -> {["lrr.status_enum = $1"], [@pending]}
        "approve" -> {["lrr.status_enum = $1"], [@approved]}
        "reject" -> {["lrr.status_enum = $1"], [300]}
      end

    {filters, params} =
      if loan_id,
        do: {filters ++ ["loan.id = $#{length(params) + 1}"], params ++ [loan_id]},
        else: {filters, params}

    where = if filters == [], do: "", else: " WHERE " <> Enum.join(filters, " AND ")

    rows(
      """
      SELECT lrr.id, lrr.status_enum, lrr.reschedule_from_date, cv.id AS reason_id, cv.code_value AS reason,
             loan.id AS loan_id, loan.account_no AS loan_account_no, client.id AS client_id,
             client.display_name AS client_name
      FROM m_loan_reschedule_request lrr
      LEFT JOIN m_loan loan ON loan.id = lrr.loan_id
      LEFT JOIN m_client client ON client.id = loan.client_id
      LEFT JOIN m_code_value cv ON cv.id = lrr.reschedule_reason_cv_id
      #{where}
      """,
      params
    )
  end

  @doc "The request with all that it says and its variations, or `nil`."
  @spec get(integer) :: map | nil
  def get(id) do
    sql = """
    SELECT lr.id, lr.loan_id, lr.status_enum, lr.reschedule_from_installment, lr.reschedule_from_date,
           lr.recalculate_interest, lr.reschedule_reason_cv_id AS reason_id, cv.code_value AS reason,
           lr.reschedule_reason_comment AS comment, lr.submitted_on_date, sbu.username AS submitted_by_username,
           sbu.firstname AS submitted_by_firstname, sbu.lastname AS submitted_by_lastname,
           lr.approved_on_date, abu.username AS approved_by_username, abu.firstname AS approved_by_firstname,
           abu.lastname AS approved_by_lastname, lr.rejected_on_date, rbu.username AS rejected_by_username,
           rbu.firstname AS rejected_by_firstname, rbu.lastname AS rejected_by_lastname,
           mc.id AS client_id, mc.display_name AS client_name, ml.account_no AS loan_account_no,
           tv.id AS term_id, tv.term_type, tv.applicable_date, tv.decimal_value, tv.date_value,
           tv.is_specific_to_installment
    FROM m_loan_reschedule_request lr
    LEFT JOIN m_code_value cv ON cv.id = lr.reschedule_reason_cv_id
    LEFT JOIN m_appuser sbu ON sbu.id = lr.submitted_by_user_id
    LEFT JOIN m_appuser abu ON abu.id = lr.approved_by_user_id
    LEFT JOIN m_appuser rbu ON rbu.id = lr.rejected_by_user_id
    LEFT JOIN m_loan ml ON ml.id = lr.loan_id
    LEFT JOIN m_client mc ON mc.id = ml.client_id
    JOIN m_loan_reschedule_request_term_variations_mapping rrtvm ON lr.id = rrtvm.loan_reschedule_request_id
    JOIN m_loan_term_variations tv ON tv.id = rrtvm.loan_term_variations_id AND tv.parent_id IS NULL
    WHERE lr.id = $1
    ORDER BY tv.id
    """

    case rows(sql, [id]) do
      [] -> nil
      [first | _] = all -> Map.put(first, :variations, Enum.map(all, &variation/1))
    end
  end

  defp variation(row) do
    %{
      id: row.term_id,
      type: row.term_type,
      from: row.applicable_date,
      decimal: row.decimal_value,
      date: row.date_value,
      specific?: row.is_specific_to_installment
    }
  end

  defp rows(sql, params) do
    %{columns: columns, rows: rows} = TenantRepo.query!(sql, params)
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
  end

  @doc "The request, or the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    sql = """
    SELECT lr.id, lr.loan_id, lr.status_enum, lr.reschedule_from_installment, lr.reschedule_from_date,
           lr.submitted_on_date
    FROM m_loan_reschedule_request lr WHERE lr.id = $1
    """

    case rows(sql, [id]) do
      [request] ->
        request

      [] ->
        raise ResourceNotFound.new(
                "error.msg.loan.reschedule.request.id.invalid",
                "Loan reschedule request with identifier #{id} does not exist",
                [id]
              )
    end
  end

  @doc "Every term variation of a loan, whatever became of the request that made it, by the date they apply from."
  @spec loan_variations(integer) :: [map]
  def loan_variations(loan_id) do
    from(t in "m_loan_term_variations",
      where: t.loan_id == ^loan_id,
      order_by: [t.applicable_date, t.id],
      select: %{
        id: t.id,
        type: t.term_type,
        from: t.applicable_date,
        decimal: t.decimal_value,
        date: t.date_value,
        specific?: t.is_specific_to_installment,
        active?: t.is_active
      }
    )
    |> TenantRepo.all()
  end

  @doc "The variations of a request, all of them, in the order they were made."
  @spec variations(integer) :: [map]
  def variations(id) do
    "SELECT tv.* FROM m_loan_term_variations tv JOIN m_loan_reschedule_request_term_variations_mapping m ON m.loan_term_variations_id = tv.id WHERE m.loan_reschedule_request_id = $1 ORDER BY tv.id"
    |> rows([id])
    |> Enum.map(fn tv ->
      %{
        id: tv.id,
        type: tv.term_type,
        from: tv.applicable_date,
        decimal: tv.decimal_value,
        date: tv.date_value,
        specific?: tv.is_specific_to_installment,
        parent_id: tv.parent_id
      }
    end)
  end

  # --- create -------------------------------------------------------------------------------------

  @doc "Creates a request to reschedule the loan the body names."
  @spec create!(struct, Params.t()) :: Result.t()
  def create!(user, %Params{} = p) do
    loan = loan!(p)

    if loan.is_charged_off do
      raise DomainRuleViolation,
        code: "error.msg.loan.is.charged.off",
        message:
          "Loan: #{loan.id} reschedule installment is not allowed. Loan Account is Charged-off",
        args: [loan.id]
    end

    Params.check_supported!(p, @create_params)
    request = read_create!(p)
    installments = Loans.installments(loan.id)
    installment = Enum.find(installments, &(&1.due_date == request.from))

    check_create!(loan, request, installment)
    reason = reason!(request.reason_id)
    refuse_unsupported!(loan, request)

    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_loan_reschedule_request",
        [
          %{
            loan_id: loan.id,
            status_enum: @pending,
            reschedule_from_installment: installment.installment,
            reschedule_from_date: request.from,
            recalculate_interest: request.recalculate,
            reschedule_reason_cv_id: reason.id,
            reschedule_reason_comment: request.comment || "",
            submitted_on_date: request.submitted_on,
            submitted_by_user_id: user.id
          }
        ],
        returning: [:id]
      )

    _refs =
      Enum.reduce(variations_for(request), %{}, fn variation, refs ->
        parent = variation[:parent_ref] && Map.fetch!(refs, variation.parent_ref)

        {1, [%{id: tv}]} =
          TenantRepo.insert_all(
            "m_loan_term_variations",
            [
              %{
                loan_id: loan.id,
                term_type: variation.type,
                applicable_date: request.from,
                decimal_value: variation[:decimal],
                date_value: variation[:date],
                is_specific_to_installment: false,
                applied_on_loan_status: loan.loan_status_id,
                is_active: false,
                parent_id: parent,
                created_by: user.id,
                last_modified_by: user.id,
                created_on_utc: now,
                last_modified_on_utc: now
              }
            ],
            returning: [:id]
          )

        TenantRepo.insert_all("m_loan_reschedule_request_term_variations_mapping", [
          %{loan_reschedule_request_id: id, loan_term_variations_id: tv}
        ])

        if variation[:ref], do: Map.put(refs, variation.ref, tv), else: refs
      end)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: loan.id,
      resource_id: id
    )
  end

  # the loan the body names: none at all is a failure of Fineract's, an unknown one not found
  defp loan!(p) do
    case Json.long(p, "loanId") do
      nil ->
        raise DataIntegrity,
          code: "error.msg.data.integrity.issue",
          message: "The given id must not be null"

      id ->
        Loans.fetch!(id)
    end
  end

  # what the body says, read in the order Fineract reads it (a value that is not what it should be fails on the spot)
  defp read_create!(p) do
    submitted_on = Params.date(p, "submittedOnDate")
    from = Params.date(p, "rescheduleFromDate")
    rate = Params.decimal_with_locale(p, "newInterestRate")
    grace_principal = Params.integer_with_locale(p, "graceOnPrincipal")
    grace_interest = Params.integer_with_locale(p, "graceOnInterest")
    extra_terms = Params.integer_with_locale(p, "extraTerms")
    reason_id = Json.long(p, "rescheduleReasonId")
    comment = Params.string(p, "rescheduleReasonComment")
    adjusted = Params.date(p, "adjustedDueDate")
    end_date = Params.date(p, "endDate")
    emi = Params.decimal_with_locale(p, "emi")

    %{
      submitted_on: submitted_on,
      from: from,
      rate: rate,
      grace_principal: grace_principal,
      grace_interest: grace_interest,
      extra_terms: extra_terms,
      reason_id: reason_id,
      comment: comment,
      adjusted: adjusted,
      end_date: end_date,
      emi: emi,
      recalculate: Params.boolean(p, "recalculateInterest"),
      any_change?:
        Enum.any?(
          ~w(graceOnPrincipal graceOnInterest extraTerms newInterestRate adjustedDueDate emi),
          &Params.exists?(p, &1)
        )
    }
  end

  # `LoanRescheduleRequestDataValidatorImpl.validateForCreateAction`
  defp check_create!(loan, r, installment) do
    v = Validation.new(@resource)
    v = check_active(v, loan)

    v =
      v
      |> Validation.param("submittedOnDate", r.submitted_on)
      |> Validation.not_null()

    v =
      if r.submitted_on &&
           Date.compare(loan.disbursedon_date || loan.expected_disbursedon_date, r.submitted_on) ==
             :gt,
         do:
           Validation.fail(
             v,
             "before.loan.disbursement.date",
             "Failed data validation due to: before.loan.disbursement.date.",
             [nil, ["Submission date cannot be before the loan disbursement date"]]
           ),
         else: v

    v =
      v
      |> Validation.param("rescheduleFromDate", r.from)
      |> Validation.not_null()
      |> Validation.param("newInterestRate", r.rate)
      |> Validation.ignore_if_null()
      |> Validation.positive_amount()

    v = zero_rate(v, loan, r.rate)

    v =
      v
      |> Validation.param("graceOnPrincipal", r.grace_principal)
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()
      |> Validation.param("graceOnInterest", r.grace_interest)
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()
      |> Validation.param("extraTerms", r.extra_terms)
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()
      |> Validation.param("rescheduleReasonId", r.reason_id)
      |> Validation.not_null()
      |> Validation.greater_than_zero()
      |> Validation.param("rescheduleReasonComment", r.comment)
      |> Validation.ignore_if_null()
      |> Validation.max_length(500)

    v =
      if r.adjusted && r.from && Date.compare(r.adjusted, r.from) == :lt,
        do:
          Validation.add_error(
            v,
            "validation.msg.#{@resource}.rescheduleFromDate.adjustedDueDate.before.rescheduleFromDate",
            "Failed data validation due to: adjustedDueDate.before.rescheduleFromDate.",
            "rescheduleFromDate",
            [nil, ["Adjusted due date cannot be before the reschedule from date"]]
          ),
        else: v

    v = check_emi(v, r)

    v =
      if r.any_change?,
        do: v,
        else: v |> Validation.param("graceOnPrincipal", nil) |> Validation.not_null()

    v = check_installment(v, installment)
    v = check_overdue_charges(v, loan, installment)
    Validation.raise_if_errors!(v)
  end

  defp zero_rate(v, loan, rate) do
    if rate != nil and Decimal.eq?(loan.annual_nominal_interest_rate, 0) and
         not Decimal.eq?(rate, 0) do
      Validation.add_error(
        v,
        "validation.msg.#{@resource}.newInterestRate.loan.reschedule.not.allowed.from.current.interest.rate.zero",
        "Failed data validation due to: loan.reschedule.not.allowed.from.current.interest.rate.zero.",
        "newInterestRate",
        [rate, ["Loan rescheduling is not allowed from interest rate 0 (zero)"]]
      )
    else
      v
    end
  end

  defp check_active(v, %{loan_status_id: 300}), do: v

  defp check_active(v, _loan),
    do:
      Validation.add_error(
        v,
        "validation.msg.#{@resource}.loan.is.not.active",
        "Failed data validation due to: loan.is.not.active.",
        nil,
        [nil, ["Loan is not active"]]
      )

  defp check_emi(v, %{emi: nil, end_date: nil}), do: v

  defp check_emi(v, r) do
    v =
      v
      |> Validation.param("endDate", r.end_date)
      |> Validation.not_null()
      |> Validation.param("emi", r.emi)
      |> Validation.not_null()
      |> Validation.positive_amount()

    if r.end_date && r.from && Date.compare(r.end_date, r.from) == :lt,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{@resource}.endDate.end.date.before.reschedule.from.date",
          "Failed data validation due to: end.date.before.reschedule.from.date.",
          "endDate",
          [nil, ["End date cannot be before the reschedule from date"]]
        ),
      else: v
  end

  defp check_installment(v, nil),
    do:
      Validation.add_error(
        v,
        "validation.msg.#{@resource}.rescheduleFromDate.repayment.schedule.installment.does.not.exist",
        "Failed data validation due to: repayment.schedule.installment.does.not.exist.",
        "rescheduleFromDate",
        [nil, ["Repayment schedule installment does not exist"]]
      )

  defp check_installment(v, %{completed: true}),
    do:
      Validation.add_error(
        v,
        "validation.msg.#{@resource}.rescheduleFromDate.repayment.schedule.installment.obligation.met",
        "Failed data validation due to: repayment.schedule.installment.obligation.met.",
        "rescheduleFromDate",
        [nil, ["Repayment schedule installment obligation met"]]
      )

  defp check_installment(v, _installment), do: v

  # a penalty for an overdue installment that falls due after the installment the loan is rescheduled from
  defp check_overdue_charges(v, _loan, nil), do: v

  defp check_overdue_charges(v, loan, installment) do
    overdue? =
      Enum.any?(Loans.charges(loan.id), fn c ->
        c.time == 9 and c.due_date != nil and
          Date.compare(c.due_date, installment.from_date) == :gt
      end)

    if overdue?,
      do: %{
        v
        | errors: [
            ECBPlatform.Errors.parameter_error(
              "validation.msg.#{@resource}.not.allowed.due.to.overdue.charges",
              "Failed data validation due to: not.allowed.due.to.overdue.charges.",
              nil,
              [nil, []]
            )
            | v.errors
          ]
      },
      else: v
  end

  defp reason!(id) do
    row = TenantRepo.one(from(v in "m_code_value", where: v.id == ^id, select: %{id: v.id}))
    row || raise Codes.value_not_found(id)
  end

  # --- what is refused as not supported yet -------------------------------------------------------

  defp refuse_unsupported!(loan, request) do
    if request.emi != nil or request.end_date != nil,
      do: unsupported!("A fixed installment amount for a span of dates")

    refuse_loan_unsupported!(loan)
  end

  @doc false
  def refuse_loan_unsupported!(loan, mode \\ :approve) do
    cond do
      loan.interest_recalculation_enabled ->
        unsupported!("Rescheduling a loan with interest recalculation")

      Decimal.eq?(loan.annual_nominal_interest_rate, 0) ->
        unsupported!("Rescheduling a loan that charges no interest")

      loan.interest_method_enum not in [0, 1] ->
        unsupported!("Rescheduling this loan")

      LoanProducts.fetch!(loan.product_id).accounting_id in [3, 4] ->
        unsupported!("Rescheduling a loan on accrual accounting")

      Loans.charges(loan.id) != [] ->
        unsupported!("Rescheduling a loan with charges")

      mode != :preview and active_variations?(loan.id) ->
        unsupported!("Rescheduling a loan that has been rescheduled")

      true ->
        :ok
    end
  end

  @doc false
  def active_variations?(loan_id), do: active_variations(loan_id) != []

  @doc "The term variations of a loan that are in force."
  @spec active_variations(integer) :: [map]
  def active_variations(loan_id), do: Enum.filter(loan_variations(loan_id), & &1.active?)

  @doc false
  def unsupported!(what) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message: "#{what} is not supported yet.",
      args: []
  end

  # the variations a request makes, in the order Fineract makes them
  defp variations_for(r) do
    []
    |> add(r.adjusted, %{type: @due_date, date: r.adjusted})
    |> add(r.rate, %{type: @interest_rate_from_installment, decimal: r.rate})
    |> add(r.grace_principal, %{
      type: @grace_on_principal,
      decimal: r.grace_principal && Decimal.new(r.grace_principal),
      ref: :grace_on_principal
    })
    |> add(r.grace_principal, %{
      type: @extend_repayment_period,
      decimal: r.grace_principal && Decimal.new(r.grace_principal),
      parent_ref: :grace_on_principal
    })
    |> add(r.grace_interest, %{
      type: @grace_on_interest,
      decimal: r.grace_interest && Decimal.new(r.grace_interest)
    })
    |> add(r.extra_terms, %{
      type: @extend_repayment_period,
      decimal: r.extra_terms && Decimal.new(r.extra_terms)
    })
  end

  defp add(list, nil, _variation), do: list
  defp add(list, _value, variation), do: list ++ [variation]

  # --- reject -------------------------------------------------------------------------------------

  @doc "Rejects a request that is still pending."
  @spec reject!(struct, integer, Params.t()) :: Result.t()
  def reject!(user, id, %Params{} = p) do
    request = fetch!(id)
    Params.check_supported!(p, @reject_params)
    on = Params.date(p, "rejectedOnDate")

    v =
      Validation.new(@resource) |> Validation.param("rejectedOnDate", on) |> Validation.not_null()

    v =
      if on && Date.compare(request.submitted_on_date, on) == :gt,
        do:
          Validation.add_error(
            v,
            "validation.msg.#{@resource}.rejectedOnDate.before.submission.date",
            "Failed data validation due to: before.submission.date.",
            "rejectedOnDate",
            [nil, ["Rejection date cannot be before the request submission date."]]
          ),
        else: v

    v =
      pending(
        v,
        request,
        "Loan reschedule request rejection is not allowed. Loan reschedule request is not in submitted and pending approval state."
      )

    Validation.raise_if_errors!(v)

    TenantRepo.update_all(from(r in "m_loan_reschedule_request", where: r.id == ^id),
      set: [status_enum: @rejected, rejected_on_date: on, rejected_by_user_id: user.id]
    )

    now = DateTime.utc_now()

    ids = for t <- variations(id), do: t.id

    TenantRepo.update_all(from(t in "m_loan_term_variations", where: t.id in ^ids),
      set: [is_active: false, last_modified_by: user.id, last_modified_on_utc: now]
    )

    loan = Loans.fetch!(request.loan_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: loan.id,
      resource_id: id,
      changes: %{
        "locale" => Params.locale(p),
        "dateFormat" => Params.date_format(p),
        "rejectedOnDate" => Params.string(p, "rejectedOnDate"),
        "rejectedByUserId" => user.id
      }
    )
  end

  @doc false
  def pending(v, %{status_enum: @pending}, _message), do: v

  def pending(v, _request, message) do
    %{
      v
      | errors: [
          ECBPlatform.Errors.parameter_error(
            "validation.msg.#{@resource}.request.is.not.in.submitted.and.pending.state",
            "Failed data validation due to: request.is.not.in.submitted.and.pending.state.",
            nil,
            [nil, [message]]
          )
          | v.errors
        ]
    }
  end

  @doc false
  def approve_params, do: @approve_params

  @doc false
  def resource, do: @resource

  @doc false
  def check_active_loan(v, loan), do: check_active(v, loan)

  @doc false
  def check_installment_of(v, loan, installment) do
    v |> check_installment(installment) |> check_overdue_charges(loan, installment)
  end
end
