defmodule ECBApiFineract.Resources.FinancialActivityAccounts do
  @moduledoc """
  `/v1/financialactivityaccounts`: which GL account each financial activity (cash at the main vault,
  fund source, asset transfer, ...) posts to. List, one mapping, the template, create, update and delete.
  Reading needs `READ_FINANCIALACTIVITYACCOUNT`.

  The template, and a mapping read with `?template=true`, list the activities and the accounts that can
  be chosen, grouped by account type.
  """
  alias ECBApiFineract.Resources.{GLAccounts, Read, Write}
  alias ECBLedger.FinancialActivities

  @resource "FINANCIALACTIVITYACCOUNT"

  @doc "`GET /financialactivityaccounts`"
  def index(conn) do
    Read.respond(conn, @resource, fn -> Enum.map(FinancialActivities.list(), &serialize/1) end)
  end

  @doc "`GET /financialactivityaccounts/template`"
  def template(conn), do: Read.respond(conn, @resource, fn -> with_options(%{}) end)

  @doc "`GET /financialactivityaccounts/:id`"
  def show(conn, raw_id) do
    with_options? = conn.query_params["template"] == "true"

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> one(id, with_options?) end)
    end)
  end

  defp one(id, with_options?) do
    with {:ok, mapping} <- FinancialActivities.get(id),
         do: mapping |> serialize() |> maybe_options(with_options?)
  end

  defp maybe_options(body, true), do: with_options(body)
  defp maybe_options(body, false), do: body

  @doc "`POST /financialactivityaccounts`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /financialactivityaccounts/:id`"
  def update(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, @resource, "UPDATE", id: &1)
      )

  @doc "`DELETE /financialactivityaccounts/:id`"
  def delete(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, @resource, "DELETE", id: &1)
      )

  defp serialize(%{id: id, activity: activity, account: account}) do
    %{
      "id" => id,
      "financialActivityData" => activity_json(activity),
      "glAccountData" => %{
        "id" => account.id,
        "name" => account.name,
        "glCode" => account.gl_code
      }
    }
  end

  defp activity_json(activity),
    do: %{
      "id" => activity.id,
      "name" => activity.name,
      "mappedGLAccountType" => activity.mapped_type.value
    }

  defp with_options(body) do
    accounts =
      for {type, list} <- FinancialActivities.account_options(), into: %{} do
        {"#{type}AccountOptions", Enum.map(list, &GLAccounts.account_json/1)}
      end

    Map.merge(body, %{
      "glAccountOptions" => accounts,
      "financialActivityOptions" => Enum.map(FinancialActivities.activities(), &activity_json/1)
    })
  end
end
