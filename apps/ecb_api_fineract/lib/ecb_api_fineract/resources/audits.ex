defmodule ECBApiFineract.Resources.Audits do
  @moduledoc """
  `/v1/audits`: every stored command, newest first, with filters; one entry with its command text; and the
  search template. Needs `READ_AUDIT`.

  Filters: `actionName`, `entityName` (prefix), `resourceId`, `makerId`, `checkerId`, `status`,
  `officeId`, `clientId`, `loanId`, `makerDateTimeFrom` and `makerDateTimeTo` (`yyyy-MM-dd HH:mm:ss`),
  `includeJson`. With `paged=true` the answer is `{totalFilteredRecords, pageItems}`; `offset`, `limit`,
  `orderBy` and `sortOrder` apply then.
  """
  alias ECBApiFineract.Resources.{AuditData, Read, Write}
  alias ECBPlatform.Audit

  @doc "`GET /audits`"
  def index(conn) do
    query = conn.query_params
    user = conn.assigns.current_user
    with_json? = query["includeJson"] == "true"

    Read.respond(conn, "AUDIT", fn ->
      criteria = criteria(query)

      if query["paged"] == "true" do
        opts = [
          limit: Read.int_param(query, "limit"),
          offset: Read.int_param(query, "offset"),
          order_by: query["orderBy"],
          sort_order: query["sortOrder"]
        ]

        %{
          "totalFilteredRecords" => Audit.count(user, criteria),
          "pageItems" =>
            Enum.map(
              Audit.entries(user, criteria, opts),
              &AuditData.entry(&1, :millis, with_json?)
            )
        }
      else
        Enum.map(Audit.entries(user, criteria), &AuditData.entry(&1, :millis, with_json?))
      end
    end)
  end

  @doc "`GET /audits/:id`"
  def show(conn, raw_id) do
    Read.respond(conn, "AUDIT", fn ->
      with {:ok, id} <- Write.id(raw_id, &Audit.not_found/1),
           {:ok, entry} <- Audit.get(conn.assigns.current_user, id),
           do: AuditData.entry(entry, :seconds, true)
    end)
  end

  @doc "`GET /audits/searchtemplate`"
  def search_template(conn) do
    Read.respond(conn, "AUDIT", fn ->
      t = Audit.search_template(conn.assigns.current_user, :audit)

      %{
        "appUsers" => for(u <- t.users, do: %{"id" => u.id, "username" => u.username}),
        "actionNames" => t.action_names,
        "entityNames" => t.entity_names,
        "statuses" =>
          for(r <- t.processing_results, do: %{"id" => r.id, "processingResult" => r.name})
      }
    end)
  end

  @doc false
  def criteria(query) do
    [
      action_name: blank_to_nil(query["actionName"]),
      entity_name: blank_to_nil(query["entityName"]),
      resource_id: Read.int_param(query, "resourceId"),
      maker_id: Read.int_param(query, "makerId"),
      checker_id: Read.int_param(query, "checkerId"),
      status: Read.int_param(query, "status"),
      office_id: Read.int_param(query, "officeId"),
      client_id: Read.int_param(query, "clientId"),
      loan_id: Read.int_param(query, "loanId"),
      maker_from: datetime(query["makerDateTimeFrom"]),
      maker_to: datetime(query["makerDateTimeTo"])
    ]
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp datetime(nil), do: nil

  defp datetime(text) do
    case NaiveDateTime.from_iso8601(String.replace(text, " ", "T")) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end
end
