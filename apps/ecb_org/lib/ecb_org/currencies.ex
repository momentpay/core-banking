defmodule ECBOrg.Currencies do
  @moduledoc """
  The currency catalogue (`m_currency`) and the currencies the organisation has selected for use
  (`m_organisation_currency`), as `GET /currencies` presents them.

  The label follows Fineract: `Name (symbol)` when the currency has a display symbol, otherwise
  `Name [CODE]`. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "`%{selected: [...], available: [...]}`: selected currencies, and the rest of the catalogue, each by name."
  @spec list() :: %{selected: [map], available: [map]}
  def list do
    selected_codes = TenantRepo.all(from(o in "m_organisation_currency", select: o.code))

    all =
      from(c in "m_currency",
        order_by: [asc: fragment("? COLLATE \"C\"", c.name)],
        select: %{
          code: c.code,
          name: c.name,
          decimal_places: c.decimal_places,
          multiples_of: c.currency_multiplesof,
          display_symbol: c.display_symbol,
          name_code: c.internationalized_name_code
        }
      )
      |> TenantRepo.all()
      |> Enum.map(&with_label/1)

    {selected, available} = Enum.split_with(all, &(&1.code in selected_codes))
    %{selected: selected, available: available}
  end

  defp with_label(currency) do
    symbol = currency.display_symbol

    label =
      if symbol in [nil, ""],
        do: "#{currency.name} [#{currency.code}]",
        else: "#{currency.name} (#{symbol})"

    Map.put(currency, :display_label, label)
  end
end
