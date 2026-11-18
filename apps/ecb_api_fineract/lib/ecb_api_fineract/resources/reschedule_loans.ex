defmodule ECBApiFineract.Resources.RescheduleLoans do
  @moduledoc """
  `/rescheduleloans`: requests to reschedule a loan, the reasons for them, and approving or rejecting one, after
  Fineract's `RescheduleLoansApiResource`.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Charges, LoanProducts, Read, Write}
  alias ECBLoans.Loans.Reschedule
  alias ECBLoans.RescheduleRequests
  alias ECBPlatform.Errors.UnrecognizedQueryParameter
  alias ECBPlatform.Security

  @resource "RESCHEDULELOAN"
  @list_commands ["all", "pending", "approve", "reject"]

  @doc "`GET /rescheduleloans/template`: the reasons a request may give"
  def template(conn) do
    Read.respond(conn, @resource, fn ->
      %{"rescheduleReasons" => LoanProducts.code_values("LoanRescheduleReason")}
    end)
  end

  @doc "`GET /rescheduleloans?command=&loanId=`"
  def index(conn) do
    q = conn.query_params
    command = q["command"]

    if command in [nil, ""] or String.downcase(command) in @list_commands,
      do: list(conn, command, q["loanId"]),
      else:
        Errors.render(conn, %UnrecognizedQueryParameter{
          name: "command",
          value: command,
          allowed: @list_commands
        })
  end

  defp list(conn, command, raw_loan_id) do
    case loan_id(raw_loan_id) do
      {:ok, loan_id} ->
        Read.respond(conn, @resource, fn ->
          (command && String.downcase(command))
          |> RescheduleRequests.list(loan_id)
          |> Enum.map(&list_item/1)
        end)

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  # a loan id that is not a number does not reach the operation
  defp loan_id(nil), do: {:ok, nil}
  defp loan_id(""), do: {:ok, nil}

  defp loan_id(text) do
    case Integer.parse(text) do
      {id, ""} -> {:ok, id}
      _ -> {:error, %Errors.PathNotFound{}}
    end
  end

  @doc "`GET /rescheduleloans/:id`: one request, nothing (204) when there is none"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      if preview?(conn.query_params["command"]),
        do: preview(conn, id),
        else: read(conn, id)
    end)
  end

  defp preview?(command) when is_binary(command),
    do: command |> String.trim() |> String.downcase() == "previewloanreschedule"

  defp preview?(_command), do: false

  defp read(conn, id) do
    case RescheduleRequests.get(id) do
      nil -> nothing(conn)
      request -> Read.respond(conn, @resource, fn -> item(request) end)
    end
  end

  defp nothing(conn) do
    case Security.validate_has_read_permission(conn.assigns.current_user, @resource) do
      :ok -> Plug.Conn.send_resp(conn, 204, "")
      {:error, error} -> Errors.render(conn, error)
    end
  end

  # the schedule the request would make
  defp preview(conn, id) do
    Read.respond(conn, @resource, fn ->
      {loan, schedule} = Reschedule.preview!(id)
      preview_json(loan, schedule)
    end)
  end

  defp preview_json(loan, s) do
    zero = Decimal.new(0)
    today = ECBPlatform.BusinessDate.current()

    %{
      "currency" => Charges.currency(currency(loan)),
      "loanTermInDays" => s.loan_term_in_days,
      "totalPrincipalDisbursed" => amount(s.principal),
      "totalPrincipalExpected" => amount(s.total_principal_expected),
      "totalPrincipalPaid" => zero,
      "totalInterestCharged" => amount(s.total_interest),
      "totalFeeChargesCharged" => amount(s.total_fees),
      "totalPenaltyChargesCharged" => amount(s.total_penalties),
      "totalRepaymentExpected" => amount(s.total_repayment_expected),
      "totalOutstanding" => zero,
      "totalCredits" => zero,
      "periods" => [disbursement(s, today) | Enum.map(s.periods, &period(&1, today))]
    }
  end

  defp currency(loan) do
    ECBLoans.LoanProducts.fetch!(loan.product_id).currency
  end

  defp disbursement(s, today) do
    zero = Decimal.new(0)

    %{
      "dueDate" => s.disbursement_date,
      "principalDisbursed" => amount(s.principal),
      "principalLoanBalanceOutstanding" => amount(s.principal),
      "feeChargesDue" => zero,
      "feeChargesOutstanding" => zero,
      "totalOriginalDueForPeriod" => zero,
      "totalDueForPeriod" => zero,
      "totalOutstandingForPeriod" => zero,
      "totalOverdue" => overdue(s.disbursement_date, today, zero),
      "totalActualCostOfLoanForPeriod" => zero,
      "downPaymentPeriod" => false
    }
  end

  # a due amount is overdue once its date is before the business date
  defp overdue(date, today, amount),
    do: if(Date.compare(date, today) == :lt, do: amount)

  defp period(p, today) do
    %{
      "period" => p.number,
      "fromDate" => p.from,
      "dueDate" => p.due,
      "daysInPeriod" => Date.diff(p.due, p.from),
      "principalOriginalDue" => amount(p.principal),
      "principalDue" => amount(p.principal),
      "principalOutstanding" => amount(p.principal),
      "principalLoanBalanceOutstanding" => amount(p.balance),
      "interestOriginalDue" => amount(p.interest),
      "interestDue" => amount(p.interest),
      "interestOutstanding" => amount(p.interest),
      "feeChargesDue" => amount(p.fees),
      "feeChargesOutstanding" => amount(p.fees),
      "penaltyChargesDue" => amount(p.penalties),
      "penaltyChargesOutstanding" => amount(p.penalties),
      "totalOriginalDueForPeriod" => amount(p.total),
      "totalDueForPeriod" => amount(p.total),
      "totalOutstandingForPeriod" => amount(p.total),
      "totalOverdue" => overdue(p.due, today, amount(p.total)),
      "totalActualCostOfLoanForPeriod" =>
        amount(p.interest |> ECBMoney.plus(p.fees) |> ECBMoney.plus(p.penalties)),
      "totalInstallmentAmountForPeriod" => amount(ECBMoney.plus(p.principal, p.interest)),
      "downPaymentPeriod" => false
    }
  end

  defp amount(%ECBMoney{amount: amount}), do: amount

  @doc "`POST /rescheduleloans`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`POST /rescheduleloans/:id?command=approve|reject`"
  def command(conn, raw_id) do
    case conn.query_params["command"] do
      command when is_binary(command) ->
        case String.downcase(String.trim(command)) do
          "approve" -> run(conn, raw_id, "APPROVE")
          "reject" -> run(conn, raw_id, "REJECT")
          _ -> unrecognized(conn, command)
        end

      other ->
        unrecognized(conn, other)
    end
  end

  defp run(conn, raw_id, action),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, action, id: &1))

  defp unrecognized(conn, value),
    do:
      Errors.render(conn, %UnrecognizedQueryParameter{
        name: "command",
        value: value,
        allowed: ["approve", "reject"]
      })

  # --- the JSON ---------------------------------------------------------------------------------

  defp list_item(r) do
    %{
      "id" => r.id,
      "loanId" => r.loan_id,
      "clientId" => r.client_id,
      "clientName" => r.client_name,
      "loanAccountNumber" => r.loan_account_no,
      "statusEnum" => status(r.status_enum),
      "rescheduleFromDate" => r.reschedule_from_date,
      "rescheduleReasonCodeValue" => reason(r.reason_id, r.reason)
    }
  end

  defp item(r) do
    %{
      "id" => r.id,
      "loanId" => r.loan_id,
      "clientId" => r.client_id,
      "clientName" => r.client_name,
      "loanAccountNumber" => r.loan_account_no,
      "statusEnum" => status(r.status_enum),
      "rescheduleFromInstallment" => r.reschedule_from_installment,
      "rescheduleFromDate" => r.reschedule_from_date,
      "recalculateInterest" => r.recalculate_interest == true,
      "rescheduleReasonCodeValue" => reason(r.reason_id, r.reason),
      "rescheduleReasonComment" => r.comment,
      "timeline" => timeline(r),
      "loanTermVariationsData" => Enum.map(r.variations, &variation/1)
    }
  end

  defp reason(nil, _name), do: nil
  defp reason(id, name), do: %{"id" => id, "name" => name}

  defp timeline(r) do
    %{
      "submittedOnDate" => r.submitted_on_date,
      "submittedByUsername" => r.submitted_by_username,
      "submittedByFirstname" => r.submitted_by_firstname,
      "submittedByLastname" => r.submitted_by_lastname,
      "approvedOnDate" => r.approved_on_date,
      "approvedByUsername" => r.approved_by_username,
      "approvedByFirstname" => r.approved_by_firstname,
      "approvedByLastname" => r.approved_by_lastname,
      "rejectedOnDate" => r.rejected_on_date,
      "rejectedByUsername" => r.rejected_by_username,
      "rejectedByFirstname" => r.rejected_by_firstname,
      "rejectedByLastname" => r.rejected_by_lastname
    }
  end

  @doc false
  def variation(v) do
    %{
      "id" => v.id,
      "termType" => term_type(v.type),
      "termVariationApplicableFrom" => v.from,
      "decimalValue" => v.decimal,
      "dateValue" => v.date,
      "isSpecificToInstallment" => v.specific?
    }
  end

  @term_types %{
    1 => "emiAmount",
    2 => "interestRate",
    3 => "principalAmount",
    4 => "dueDate",
    5 => "insertInstallment",
    6 => "deleteInstallment",
    7 => "graceOnInterest",
    8 => "graceOnPrincipal",
    9 => "extendRepaymentPeriod",
    10 => "interestRateFromInstallment",
    11 => "interestPause"
  }

  # an inserted installment carries the code of a due date, a rate from an installment a value of its own
  defp term_type(type) do
    name = Map.fetch!(@term_types, type)
    code = if type == 5, do: "dueDate", else: name
    value = if type == 10, do: "interestRateForInstallment", else: name
    %{"id" => type, "code" => "loanTermType." <> code, "value" => value}
  end

  defp status(100),
    do:
      status(
        100,
        "loanStatusType.submitted.and.pending.approval",
        "Submitted and pending approval"
      )

  defp status(200), do: status(200, "loanStatusType.approved", "Approved")
  defp status(500), do: status(500, "loanStatusType.rejected", "Rejected")

  defp status(id, code, value) do
    %{
      "id" => id,
      "code" => code,
      "value" => value,
      "pendingApproval" => id == 100,
      "approved" => id == 200,
      "rejected" => id == 500
    }
  end
end
