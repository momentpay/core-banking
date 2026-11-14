defmodule ECBApiFineract.Resources.Organisation do
  @moduledoc """
  Read endpoints for the organisation's reference data: currencies, codes, payment types, working days,
  funds, holidays, staff and account-number formats. Each needs `READ_<RESOURCE>`.
  """
  alias ECBApiFineract.Resources.Read

  alias ECBOrg.{
    AccountNumberFormats,
    Codes,
    Currencies,
    Funds,
    Holidays,
    PaymentTypes,
    Staff,
    WorkingDays
  }

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

  @doc "`GET /codes`"
  def codes(conn) do
    Read.respond(conn, "CODE", fn ->
      for c <- Codes.list(),
          do: %{"id" => c.id, "name" => c.name, "systemDefined" => c.system_defined}
    end)
  end

  @doc "`GET /paymenttypes`"
  def payment_types(conn) do
    Read.respond(conn, "PAYMENTTYPE", fn ->
      for p <- PaymentTypes.list() do
        %{
          "id" => p.id,
          "name" => p.name,
          "description" => p.description,
          "isCashPayment" => p.is_cash_payment,
          "position" => p.position,
          "codeName" => p.code_name,
          "isSystemDefined" => p.is_system_defined
        }
      end
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

  @doc "`GET /workingdays/template`"
  def working_days_template(conn) do
    Read.respond(conn, "WORKINGDAYS", fn ->
      %{
        "repaymentRescheduleOptions" => Enum.map(WorkingDays.reschedule_options(), &Read.option/1)
      }
    end)
  end

  @doc "`GET /funds`"
  def funds(conn) do
    Read.respond(conn, "FUND", fn ->
      for f <- Funds.list(), do: %{"id" => f.id, "name" => f.name, "externalId" => f.external_id}
    end)
  end

  @doc "`GET /holidays` (optionally `?officeId=`)"
  def holidays(conn) do
    Read.respond(conn, "HOLIDAY", fn ->
      for h <- Holidays.list(office_id: Read.int_param(conn.query_params, "officeId")) do
        %{
          "id" => h.id,
          "name" => h.name,
          "fromDate" => h.from_date,
          "toDate" => h.to_date,
          "repaymentsRescheduledTo" => h.repayments_rescheduled_to,
          "status" => Read.option(h.status),
          "reschedulingType" => h.rescheduling_type,
          "description" => h.description
        }
      end
    end)
  end

  @doc "`GET /holidays/template`"
  def holidays_template(conn) do
    Read.respond(conn, "HOLIDAY", fn ->
      Enum.map(Holidays.rescheduling_types(), &Read.option/1)
    end)
  end

  @doc "`GET /staff` (optionally `?officeId=`, `?status=`, `?loanOfficersOnly=`)"
  def staff(conn) do
    params = conn.query_params

    Read.respond(conn, "STAFF", fn ->
      opts = [
        office_id: Read.int_param(params, "officeId"),
        loan_officers_only: params["loanOfficersOnly"] == "true",
        status: params["status"]
      ]

      for s <- Staff.list(conn.assigns.current_user, opts) do
        %{
          "id" => s.id,
          "firstname" => s.firstname,
          "lastname" => s.lastname,
          "displayName" => s.display_name,
          "officeId" => s.office_id,
          "officeName" => s.office_name,
          "isLoanOfficer" => s.is_loan_officer,
          "externalId" => s.external_id,
          "mobileNo" => s.mobile_no,
          "emailAddress" => s.email_address,
          "isActive" => s.is_active,
          "joiningDate" => s.joining_date
        }
      end
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
