defmodule ECBApiFineract.Resources.LoanCharges do
  @moduledoc """
  `/loans/{id}/charges`: the charges of a loan, one of them, the template for adding one, and adding, waiving,
  paying, changing and deleting them, after Fineract's `LoanChargesApiResource`.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{LoanAccounts, LoanTemplate, Read, Write}
  alias ECBLoans.Loans
  alias ECBPlatform.Errors.{ResourceNotFound, UnrecognizedQueryParameter}
  alias ECBPlatform.TenantRepo

  import Ecto.Query

  @resource "LOAN"
  @entity "LOANCHARGE"
  @commands %{"waive" => "WAIVE", "pay" => "PAY", "adjustment" => "ADJUSTMENT"}

  @doc "`GET /loans/:id/charges`"
  def index(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        loan = Loans.fetch!(id)

        id
        |> Loans.charges()
        |> Enum.sort_by(&order(&1, loan))
        |> Enum.map(&LoanAccounts.charge_json(&1, loan))
      end)
    end)
  end

  # by the day each falls due (a charge with no day on the day the loan is paid out), then its time, then
  # fees before penalties
  defp order(c, loan) do
    day = c.due_date || loan.disbursedon_date || loan.expected_disbursedon_date

    {Date.to_gregorian_days(day), c.time, c.due_date && Date.to_gregorian_days(c.due_date),
     c.penalty}
  end

  @doc "`GET /loans/:id/charges/template`"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        loan = Loans.fetch!(id)

        %{
          "amountPaid" => 0,
          "amountWaived" => 0,
          "amountWrittenOff" => 0,
          "chargeOptions" => LoanTemplate.charge_options_in(loan.currency_code),
          "penalty" => false,
          "paid" => false,
          "waived" => false,
          "chargePayable" => false
        }
      end)
    end)
  end

  @doc "`GET /loans/:id/charges/:charge_id`"
  def show(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      Read.respond(conn, @resource, fn -> one(id, charge_id) end)
    end)
  end

  defp one(id, charge_id) do
    loan = Loans.fetch!(id)

    case Loans.charge(id, charge_id) do
      nil ->
        {:error, not_found(id, charge_id)}

      c ->
        c |> LoanAccounts.charge_json(loan) |> Map.put("installmentChargeData", installments(c))
    end
  end

  # the loan and the charge named in a path
  defp with_ids(conn, raw_id, raw_charge_id, fun) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, charge_id} <- Write.path_id(raw_charge_id) do
      fun.(id, charge_id)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp installments(%{time: 8, id: id}) do
    for i <- Loans.installment_charges(id), not i.paid, not i.waived do
      Map.reject(
        %{
          "installmentNumber" => i.installment,
          "dueDate" => i.due_date,
          "amount" => i.amount,
          "amountOutstanding" => i.outstanding,
          "amountWaived" => i.waived_amount,
          "paid" => i.paid,
          "waived" => i.waived
        },
        fn {_k, v} -> is_nil(v) end
      )
    end
  end

  defp installments(_charge), do: []

  defp not_found(loan_id, charge_id) do
    if TenantRepo.exists?(from(c in "m_loan_charge", where: c.id == ^charge_id)) do
      ResourceNotFound.new(
        "error.msg.loanCharge.id.invalid.for.given.loan",
        "Loan charge with identifier #{charge_id} does not exist for loan #{loan_id}",
        [charge_id, loan_id]
      )
    else
      ResourceNotFound.new(
        "error.msg.loanCharge.id.invalid",
        "Loan charge with identifier #{charge_id} does not exist",
        [charge_id]
      )
    end
  end

  @doc "`POST /loans/:id/charges`"
  def create(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @entity, "CREATE", id: &1))

  @doc "`POST /loans/:id/charges/:charge_id?command=waive|pay`"
  def command(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      case Map.fetch(@commands, conn.query_params["command"]) do
        {:ok, action} ->
          Write.execute(conn, @entity, action, id: id, subentity_id: charge_id)

        :error ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: conn.query_params["command"],
            allowed: []
          })
      end
    end)
  end

  @doc "`PUT /loans/:id/charges/:charge_id`"
  def update(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      Write.execute(conn, @entity, "UPDATE", id: id, subentity_id: charge_id)
    end)
  end

  @doc "`DELETE /loans/:id/charges/:charge_id`"
  def delete(conn, raw_id, raw_charge_id) do
    with_ids(conn, raw_id, raw_charge_id, fn id, charge_id ->
      Write.execute(conn, @entity, "DELETE", id: id, subentity_id: charge_id)
    end)
  end
end
