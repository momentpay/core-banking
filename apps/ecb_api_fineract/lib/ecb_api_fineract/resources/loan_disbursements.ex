defmodule ECBApiFineract.Resources.LoanDisbursements do
  @moduledoc """
  `/loans/{id}/disbursements`: one tranche of a loan, changing one, and adding, changing and removing them all at
  once (`editDisbursements`), after Fineract's `LoanDisbursementDetailApiResource`.
  """
  alias ECBApiFineract.Resources.{LoanAccounts, Read, Write}
  alias ECBLoans.Tranches
  alias ECBPlatform.Errors.ServerError

  @resource "LOAN"
  @choosable ~w(id expectedDisbursementDate actualDisbursementDate principal approvedPrincipal)

  @doc "`GET /loans/:id/disbursements/:disbursement_id`"
  def show(conn, raw_id, raw_disbursement_id) do
    with_ids(conn, raw_id, raw_disbursement_id, fn id, disbursement_id ->
      Read.respond(conn, @resource, fn ->
        read(Tranches.get(id, disbursement_id), conn.query_params)
      end)
    end)
  end

  # Fineract has nothing to answer with and fails with its plain server error
  defp read(nil, _query), do: {:error, %ServerError{}}
  defp read(tranche, query), do: tranche |> item() |> LoanAccounts.only_fields(query, @choosable)

  defp item(t) do
    base = %{
      "id" => t.id,
      "loanId" => t.loan_id,
      "expectedDisbursementDate" => t.expected_date,
      "principal" => t.principal,
      "disburseChargeAmount" => 0
    }

    if t.disbursed_on, do: Map.put(base, "actualDisbursementDate", t.disbursed_on), else: base
  end

  @doc "`PUT /loans/:id/disbursements/editDisbursements`"
  def update_all(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "DISBURSEMENTDETAIL", "UPDATE", id: &1)
      )

  @doc "`PUT /loans/:id/disbursements/:disbursement_id`"
  def update(conn, raw_id, raw_disbursement_id) do
    with_ids(conn, raw_id, raw_disbursement_id, fn id, disbursement_id ->
      Write.execute(conn, "DISBURSEMENTDETAIL", "UPDATE", id: id, subentity_id: disbursement_id)
    end)
  end

  defp with_ids(conn, raw_id, raw_disbursement_id, fun) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, disbursement_id} <- Write.path_id(raw_disbursement_id) do
      fun.(id, disbursement_id)
    else
      {:error, error} -> ECBApiFineract.Errors.render(conn, error)
    end
  end
end
