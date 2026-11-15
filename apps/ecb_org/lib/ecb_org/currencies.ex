defmodule ECBOrg.Currencies do
  @moduledoc """
  The currency catalogue (`m_currency`) and the currencies the organisation has selected for use
  (`m_organisation_currency`), as `GET /currencies` presents them.

  The label follows Fineract: `Name (symbol)` when the currency has a display symbol, otherwise
  `Name [CODE]`. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
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

  @doc """
  Checks that the organisation has selected `code`, raising a not-found error with Fineract's wording when
  it has not (an unknown code and an unselected one are the same to the caller).
  """
  @spec fetch_selected!(String.t() | nil) :: :ok
  def fetch_selected!(code) do
    if code && TenantRepo.exists?(from(o in "m_organisation_currency", where: o.code == ^code)) do
      :ok
    else
      raise ResourceNotFound,
        code: "error.msg.currency.currencyCode.invalid.or.not.supported",
        message:
          "Currency with identifier #{code} does not exist or is not supported by the Organization",
        args: [code]
    end
  end

  @doc "The label a client shows for a currency: `Name (symbol)`, or `Name [CODE]` when it has no symbol."
  @spec display_label(String.t(), String.t(), String.t() | nil) :: String.t()
  def display_label(name, code, symbol) do
    if symbol in [nil, ""], do: "#{name} [#{code}]", else: "#{name} (#{symbol})"
  end

  defp with_label(currency),
    do:
      Map.put(
        currency,
        :display_label,
        display_label(currency.name, currency.code, currency.display_symbol)
      )
end
