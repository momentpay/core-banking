defmodule ECBApiFineract.Resources.AuditData do
  @moduledoc """
  How audit entries are written as JSON, in Fineract's two date styles: the audit list gives the time as
  whole milliseconds since 1970, the maker-checker list and a single entry as seconds with a fraction
  (`1794680071.13689`).
  """

  @doc "One entry. `date_style` is `:millis` or `:seconds`; the command text is shown when `with_json?`."
  @spec entry(map, :millis | :seconds, boolean) :: map
  def entry(e, date_style, with_json?) do
    %{
      "id" => e.id,
      "actionName" => e.action_name,
      "entityName" => e.entity_name,
      "resourceId" => e.resource_id,
      "subresourceId" => e.subresource_id,
      "clientId" => e.client_id,
      "loanId" => e.loan_id,
      "maker" => e.maker,
      "madeOnDate" => date(e.made_on, date_style),
      "checker" => e.checker,
      "checkedOnDate" => date(e.checked_on, date_style),
      "processingResult" => e.processing_result,
      "commandAsJson" => if(with_json? or Map.get(e, :with_json), do: e.command_as_json),
      "officeName" => e.office_name,
      "url" => e.url || "",
      "ip" => e.ip || ""
    }
  end

  defp date(nil, _style), do: nil
  defp date(%DateTime{} = dt, :millis), do: DateTime.to_unix(dt, :millisecond)

  defp date(%DateTime{} = dt, :seconds) do
    dt
    |> DateTime.to_unix(:microsecond)
    |> Decimal.new()
    |> Decimal.div(1_000_000)
    |> Decimal.normalize()
  end
end
