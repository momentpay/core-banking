defmodule ECBLedger.Journal.OpeningBalance do
  @moduledoc """
  The opening balances of an office, following Fineract's `retrieveOfficeOpeningBalances`: every enabled
  detail account except the contra account, grouped by type, each with the entry that set its opening
  balance when there is one. The contra account is the equity account mapped to the "opening balances
  transfer contra" financial activity. Must run inside a tenant scope.
  """
  alias ECBLedger.{FinancialActivities, GLAccounts, Journal}
  alias ECBOrg.Offices
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Errors.DomainRuleViolation

  @contra_activity 300
  @equity 3

  @doc """
  The opening balances of `office_id` in `currency_code`. Raises when the contra activity has no
  account, when that account is not an equity account, or when the office does not exist.
  """
  @spec retrieve!(integer | nil, String.t() | nil) :: map
  def retrieve!(office_id, currency_code) do
    contra_id = FinancialActivities.mapped_account!(@contra_activity).id
    contra = GLAccounts.fetch!(contra_id)

    if contra.type_id != @equity do
      raise DomainRuleViolation,
        code:
          "error.msg.configuration.opening.balance.contra.account.value.is.invalid.account.type",
        message:
          "Global configuration 'office-opening-balances-contra-account' value is not an equity type account",
        args: [contra_id]
    end

    office = office!(office_id)
    existing = existing(office_id, contra_id, currency_code)

    rows =
      for account <- GLAccounts.list(disabled: false, usage: 1), account.id != contra_id do
        case Enum.find(existing, &(&1.gl_account_id == account.id)) do
          nil -> {:account, account}
          entry -> {:entry, entry}
        end
      end

    %{
      office_id: office_id,
      office_name: office.name,
      date: BusinessDate.current(),
      contra: contra,
      rows: rows
    }
  end

  # The entries of the last transaction that touched the contra account in this office and currency.
  defp existing(office_id, contra_id, currency_code) do
    %{items: on_contra} =
      Journal.list(
        office_id: office_id,
        currency_code: currency_code,
        gl_account_id: contra_id,
        order_by: "journalEntry.id",
        sort_order: "ASC"
      )

    case List.last(on_contra) do
      nil ->
        []

      last ->
        Journal.list(
          office_id: office_id,
          currency_code: currency_code,
          transaction_id: last.transaction_id
        ).items
    end
  end

  # no office is a crash in Fineract, and an unknown one is a not-found
  defp office!(nil), do: raise(ECBLedger.Errors.ServerError)

  defp office!(office_id) do
    case Offices.get(office_id) do
      {:ok, office} -> office
      {:error, error} -> raise error
    end
  end
end
