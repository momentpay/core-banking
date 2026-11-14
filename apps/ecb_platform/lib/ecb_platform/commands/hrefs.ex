defmodule ECBPlatform.Commands.Hrefs do
  @moduledoc """
  The URL Fineract stores with a command (`m_portfolio_command_source.api_get_url`) so that the audit and
  maker-checker lists can point at what a command made: `/funds/template` for a new fund, `/funds/7` for
  a change to fund 7.

  The templates are extracted from Fineract's `CommandWrapperBuilder` by `parity/tools/command_hrefs.py`
  into `priv/command_hrefs.json`. A command Fineract gives no URL (the newer typed ones) gets the plain path of its entity.
  """

  @path Path.expand("../../../priv/command_hrefs.json", __DIR__)
  @external_resource @path
  @templates @path |> File.read!() |> Jason.decode!()

  @doc "The URL recorded for a command, with the ids filled in."
  @spec resolve(String.t(), String.t(), integer | nil, integer | nil) :: String.t()
  def resolve(entity, action, entity_id, subentity_id) do
    case Map.get(@templates, "#{entity}|#{action}") do
      nil ->
        fallback(entity, entity_id)

      template ->
        template
        |> String.replace("{entityId}", to_string(entity_id))
        |> String.replace("{subentityId}", to_string(subentity_id))
        |> String.replace("{?}", "")
    end
  end

  defp fallback(entity, nil), do: "/" <> String.downcase(entity)

  defp fallback(entity, entity_id),
    do: "/" <> String.downcase(entity) <> "/" <> to_string(entity_id)
end
