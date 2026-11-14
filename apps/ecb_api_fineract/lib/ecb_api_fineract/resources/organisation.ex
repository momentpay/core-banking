defmodule ECBApiFineract.Resources.Organisation do
  @moduledoc """
  Endpoints for the organisation's reference data: currencies, working days and account-number
  formats (codes, funds, holidays, payment types and staff have their own modules). Each needs
  `READ_<RESOURCE>`.
  """
  alias ECBApiFineract.Resources.Read
  alias ECBOrg.{AccountNumberFormats, Currencies, WorkingDays}

  @doc "`GET /currencies`"
  def currencies(conn) do
    Read.respond(conn, "CURRENCY", fn ->
      %{selected: selected, available: available} = Currencies.list()

      %{
        "selectedCurrencyOptions" => Enum.map(selected, &currency/1),
        "currencyOptions" => Enum.map(available, &currency/1)
      }
    end)
  end

  @doc "`GET /workingdays`"
  def working_days(conn) do
    Read.respond(conn, "WORKINGDAYS", fn ->
      case WorkingDays.get() do
        nil ->
          %{}

        w ->
          %{
            "id" => w.id,
            "recurrence" => w.recurrence,
            "repaymentRescheduleType" =>
              w.repayment_reschedule_type && Read.option(w.repayment_reschedule_type),
            "extendTermForDailyRepayments" => w.extend_term_for_daily_repayments,
            "extendTermForRepaymentsOnHolidays" => w.extend_term_for_repayments_on_holidays,
            "repaymentRescheduleOptions" =>
              Enum.map(WorkingDays.reschedule_options(), &Read.option/1)
          }
      end
    end)
  end

  @doc "`PUT /workingdays`"
  def update_working_days(conn),
    do: ECBApiFineract.Resources.Write.execute(conn, "WORKINGDAYS", "UPDATE")

  @doc "`GET /workingdays/template`"
  def working_days_template(conn) do
    Read.respond(conn, "WORKINGDAYS", fn ->
      %{
        "repaymentRescheduleOptions" => Enum.map(WorkingDays.reschedule_options(), &Read.option/1)
      }
    end)
  end

  @doc "`GET /accountnumberformats`"
  def account_number_formats(conn) do
    Read.respond(conn, "ACCOUNTNUMBERFORMAT", fn ->
      for f <- AccountNumberFormats.list() do
        %{
          "id" => f.id,
          "accountType" => Read.option(f.account_type),
          "prefixType" => f.prefix_type && Read.option(f.prefix_type),
          "prefixCharacter" => f.prefix_character
        }
      end
    end)
  end

  @doc "`GET /accountnumberformats/template`"
  def account_number_formats_template(conn) do
    Read.respond(conn, "ACCOUNTNUMBERFORMAT", fn ->
      t = AccountNumberFormats.template()

      %{
        "accountTypeOptions" => Enum.map(t.account_type_options, &Read.option/1),
        "prefixTypeOptions" =>
          Map.new(t.prefix_type_options, fn {type, options} ->
            {type, Enum.map(options, &Read.option/1)}
          end)
      }
    end)
  end

  defp currency(c) do
    %{
      "code" => c.code,
      "name" => c.name,
      "decimalPlaces" => c.decimal_places,
      "inMultiplesOf" => c.multiples_of,
      "displaySymbol" => if(c.display_symbol in [nil, ""], do: nil, else: c.display_symbol),
      "nameCode" => c.name_code,
      "displayLabel" => c.display_label
    }
  end
end
