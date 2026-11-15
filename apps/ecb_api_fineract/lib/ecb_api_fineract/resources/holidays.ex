defmodule ECBApiFineract.Resources.Holidays do
  @moduledoc """
  `/v1/holidays`: list (for an office), one holiday, the template, create, update, delete and activate.

  The list needs an `officeId`; `fromDate` and `toDate` narrow it and must come with a `dateFormat` and a
  `locale`. Activation is `POST /holidays/:id?command=activate`.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.Holidays
  alias ECBPlatform.Errors.UnrecognizedQueryParameter
  alias ECBPlatform.Params

  @doc "`GET /holidays`"
  def index(conn) do
    query = conn.query_params

    Read.respond(conn, "HOLIDAY", fn ->
      dates = Params.parse!(Jason.encode!(with_locale(query)))

      opts = [from_date: Params.date(dates, "fromDate"), to_date: Params.date(dates, "toDate")]
      Enum.map(Holidays.list(Read.int_param(query, "officeId"), opts), &serialize/1)
    end)
  end

  @doc "`GET /holidays/:id`"
  def show(conn, raw_id) do
    Read.respond(conn, "HOLIDAY", fn ->
      with {:ok, id} <- Write.path_id(raw_id),
           {:ok, holiday} <- Holidays.get(id),
           do: serialize(holiday)
    end)
  end

  @doc "`GET /holidays/template`"
  def template(conn) do
    Read.respond(conn, "HOLIDAY", fn ->
      Enum.map(Holidays.rescheduling_types(), &Read.option/1)
    end)
  end

  @doc "`POST /holidays`"
  def create(conn), do: Write.execute(conn, "HOLIDAY", "CREATE")

  @doc "`POST /holidays/:id?command=activate`"
  def command(conn, raw_id) do
    case conn.query_params["command"] do
      "activate" ->
        Write.with_path_id(
          conn,
          raw_id,
          &Write.execute(conn, "HOLIDAY", "ACTIVATE", id: &1)
        )

      other ->
        Errors.render(conn, %UnrecognizedQueryParameter{
          name: "command",
          value: other,
          allowed: ["activate"]
        })
    end
  end

  @doc "`PUT /holidays/:id`"
  def update(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "HOLIDAY", "UPDATE", id: &1)
      )

  @doc "`DELETE /holidays/:id`"
  def delete(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "HOLIDAY", "DELETE", id: &1)
      )

  # A date in the query string needs a locale: an absent one is reported as blank, as Fineract does.
  defp with_locale(query) do
    if Map.has_key?(query, "fromDate") or Map.has_key?(query, "toDate"),
      do: Map.put_new(query, "locale", ""),
      else: query
  end

  defp serialize(h) do
    %{
      "id" => h.id,
      "name" => h.name,
      "description" => h.description,
      "fromDate" => h.from_date,
      "toDate" => h.to_date,
      "repaymentsRescheduledTo" => h.repayments_rescheduled_to,
      "status" => Read.option(h.status),
      "reschedulingType" => h.rescheduling_type
    }
  end
end
