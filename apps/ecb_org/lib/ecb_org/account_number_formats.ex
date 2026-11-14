defmodule ECBOrg.AccountNumberFormats do
  @moduledoc """
  Account-number formats (`c_account_number_format`): how the number of a new client, loan or savings
  account is built. Read side, with Fineract's fixed option lists. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @account_types [
    {1, "accountType.client", "CLIENT"},
    {2, "accountType.loan", "LOAN"},
    {3, "accountType.savings", "SAVINGS"},
    {4, "accountType.center", "CENTER"},
    {5, "accountType.group", "GROUP"},
    {6, "accountType.shares", "SHARES"},
    {7, "accountType.workingCapitalLoan", "WORKING_CAPITAL_LOAN"}
  ]

  @prefix_types [
    {1, "accountNumberPrefixType.officeName", "OFFICE_NAME"},
    {101, "accountNumberPrefixType.clientType", "CLIENT_TYPE"},
    {201, "accountNumberPrefixType.loanProductShortName", "LOAN_PRODUCT_SHORT_NAME"},
    {301, "accountNumberPrefixType.savingsProductShortName", "SAVINGS_PRODUCT_SHORT_NAME"},
    {401, "accountNumberPrefixType.prefixShortName", "PREFIX_SHORT_NAME"}
  ]

  # Which prefix types make sense for each account type, in the order Fineract lists them.
  @prefix_by_account %{
    1 => [401, 101, 1],
    2 => [401, 1, 201],
    3 => [301, 401, 1],
    4 => [1],
    5 => [1],
    6 => [],
    7 => [401, 1, 201]
  }

  @doc "Every stored format, by id."
  @spec list() :: [map]
  def list do
    from(f in "c_account_number_format",
      order_by: f.id,
      select: %{
        id: f.id,
        account_type_id: f.account_type_enum,
        prefix_type_id: f.prefix_type_enum,
        prefix_character: f.prefix_character
      }
    )
    |> TenantRepo.all()
    |> Enum.map(fn f ->
      f
      |> Map.put(:account_type, option(@account_types, f.account_type_id))
      |> Map.put(:prefix_type, f.prefix_type_id && option(@prefix_types, f.prefix_type_id))
    end)
  end

  @doc "The choices for a new format: account types, and for each the prefix types it allows."
  @spec template() :: %{account_type_options: [map], prefix_type_options: %{String.t() => [map]}}
  def template do
    %{
      account_type_options: Enum.map(@account_types, &to_option/1),
      prefix_type_options:
        Map.new(@account_types, fn {id, code, _} ->
          {code, for(p <- @prefix_by_account[id], do: option(@prefix_types, p))}
        end)
    }
  end

  defp option(list, id), do: list |> List.keyfind!(id, 0) |> to_option()
  defp to_option({id, code, value}), do: %{id: id, code: code, value: value}
end
