defmodule ECBApiFineract.Resources.LoanTemplate do
  @moduledoc """
  `GET /loans/template`: what a form for a new loan needs, after Fineract's `LoansApiResource.template` and
  `LoanReadPlatformServiceImpl.retrieveLoanProductDetailsTemplate`.

  The template type is required: `individual` (a client's loan), `collateral` (only the collateral choices),
  and `group`, `jlg` and `jlgbulk` for group loans, which are not built and answer as Fineract does for a group
  that does not exist. With a product the template carries the product's defaults; with a client, the client, the
  loan officers of the client's office and above, and the date the loan would be paid out (the business date).
  Linking a savings account is not built, so a client's linking options are empty.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Charges, LoanAccounts, LoanProducts, Read}
  alias ECBCatalog.Charges, as: Catalog
  alias ECBLoans.Loans
  alias ECBOrg.{Codes, Funds}
  alias ECBParty.{Clients, Lookups}
  alias ECBPlatform.{BusinessDate, TenantRepo}
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}

  import Ecto.Query

  @doc "`GET /loans/template`"
  def show(conn) do
    q = conn.query_params

    with {:ok, client_id} <- long(q["clientId"]),
         {:ok, group_id} <- long(q["groupId"]),
         {:ok, product_id} <- long(q["productId"]) do
      Read.respond(conn, "LOAN", fn ->
        template(q["templateType"], client_id, group_id, product_id, q)
        |> LoanAccounts.only_fields(q)
      end)
    else
      :error -> Errors.spring(conn, 404, "Not Found")
    end
  end

  # a query value that is not a whole number is turned away by the web container
  defp long(nil), do: {:ok, nil}

  defp long(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp template(type, client_id, group_id, product_id, q) do
    product = product_id && product(product_id)
    base = if product, do: product_part(product, client_id, q), else: %{}

    case type do
      nil ->
        raise DomainRuleViolation,
          code: "error.msg.loan.template.type.required",
          message: "Loan template type must be provided",
          args: []

      "collateral" ->
        base |> Map.merge(common()) |> Map.put("loanCollateralOptions", collateral_options())

      type when type in ["individual", "jlg", "jlgbulk", "group"] ->
        individual(type, base, client_id, group_id, q)

      type ->
        raise DomainRuleViolation,
          code: "error.msg.loan.template.type.not.supported",
          message: "Loan template type '#{type}' is not supported",
          args: [type]
    end
  end

  defp individual(type, base, client_id, group_id, q) do
    client = if type in ["individual", "jlg"] and client_id, do: client!(client_id)
    if type != "individual", do: group!(group_id)

    base
    |> Map.merge(common())
    |> Map.merge(client_part(client, q))
    |> Map.put("productOptions", product_options(q["activeOnly"] == "true"))
    |> Map.put("isRatesEnabled", false)
  end

  # groups are not built, so no group exists
  defp group!(nil) do
    raise ResourceNotFound,
      code: "error.msg.group.id.invalid",
      message: "Group with identifier null does not exist",
      args: [nil]
  end

  defp group!(id), do: Lookups.group!(id)

  defp common do
    %{
      "isLoanProductLinkedToFloatingRate" => false,
      "isFloatingInterestRate" => false,
      "isTopup" => false,
      "fraud" => false,
      "isInterestRecalculationEnabled" => false
    }
  end

  # --- the client --------------------------------------------------------------------------------

  defp client!(id) do
    case Clients.find(id) do
      {:ok, client} ->
        client

      {:error, _} ->
        raise ResourceNotFound,
          code: "error.msg.client.not.found.with.client.id",
          message: "Client not found with valuer #{id}.",
          args: [to_string(id)]
    end
  end

  defp client_part(nil, _q), do: %{}

  defp client_part(client, q) do
    on = BusinessDate.current()

    %{
      "clientId" => client.id,
      "clientAccountNo" => client.account_no,
      "clientName" => client.display_name,
      "clientOfficeId" => client.office_id,
      "timeline" => %{"expectedDisbursementDate" => on},
      "expectedDisbursementDate" => on,
      "loanOfficerOptions" =>
        loan_officers(client.office_id, q["staffInSelectedOfficeOnly"] == "true"),
      "accountLinkingOptions" => []
    }
  end

  # the loan officers of the office, and of the offices above it unless only its own are asked for
  defp loan_officers(office_id, own_only?) do
    from(s in "m_staff",
      join: o in "m_office",
      on: o.id == s.office_id,
      join: sel in "m_office",
      on: sel.id == ^office_id,
      where: s.is_loan_officer == true and s.is_active == true,
      order_by: [asc: fragment("? COLLATE \"C\"", s.display_name), asc: s.id],
      select: %{
        id: s.id,
        firstname: s.firstname,
        lastname: s.lastname,
        display_name: s.display_name,
        office_id: s.office_id,
        office_name: o.name,
        is_loan_officer: s.is_loan_officer,
        is_active: s.is_active,
        joining_date: s.joining_date,
        hierarchy: o.hierarchy,
        selected: sel.hierarchy
      }
    )
    |> TenantRepo.all()
    |> Enum.filter(&office_allowed?(&1, own_only?, office_id))
    |> Enum.map(&officer/1)
  end

  defp office_allowed?(s, true, office_id), do: s.office_id == office_id
  defp office_allowed?(s, false, _office_id), do: String.starts_with?(s.selected, s.hierarchy)

  defp officer(s) do
    %{
      "id" => s.id,
      "firstname" => s.firstname,
      "lastname" => s.lastname,
      "displayName" => s.display_name,
      "officeId" => s.office_id,
      "officeName" => s.office_name,
      "isLoanOfficer" => s.is_loan_officer,
      "isActive" => s.is_active,
      "joiningDate" => s.joining_date,
      "dateFormat" => "dd MMMM yyyy"
    }
  end

  # --- the product -------------------------------------------------------------------------------

  defp product(id) do
    case ECBLoans.LoanProducts.get(id) do
      {:ok, _} ->
        LoanProducts.detail(id)

      {:error, _} ->
        raise ResourceNotFound,
          code: "error.msg.loanproduct.id.invalid",
          message: "Loan product with identifier #{id} does not exist",
          args: [id]
    end
  end

  defp product_options(active_only?) do
    keys = Loans.template_static()["productOptionKeys"]

    for p <- ECBLoans.LoanProducts.list(),
        detail = LoanProducts.detail(p.id),
        not active_only? or detail["status"] == "loanProduct.active",
        do: Map.take(detail, keys)
  end

  defp product_part(p, client_id, _q) do
    {charges, overdue} = Enum.split_with(p["charges"], &(&1["chargeTimeType"]["id"] != 9))
    loan_charges = Enum.map(charges, &loan_charge(&1, p))
    principal = p["principal"]
    repayments = p["numberOfRepayments"]

    net =
      Enum.reduce(loan_charges, principal, fn c, net -> Decimal.sub(net, c["amount"]) end)

    static = Loans.template_static()
    _ = client_id

    %{
      "productId" => p["id"],
      "loanProductName" => p["name"],
      "loanProductDescription" => p["description"],
      "isLoanProductLinkedToFloatingRate" => p["isLinkedToFloatingInterestRates"],
      "fundId" => p["fundId"],
      "fundName" => p["fundName"],
      "currency" => p["currency"],
      "proposedPrincipal" => principal,
      "principal" => principal,
      "approvedPrincipal" => principal,
      "netDisbursalAmount" => net,
      "inArrearsTolerance" => p["inArrearsTolerance"],
      "termFrequency" => repayments * p["repaymentEvery"],
      "termPeriodFrequencyType" => p["repaymentFrequencyType"],
      "numberOfRepayments" => repayments,
      "repaymentEvery" => p["repaymentEvery"],
      "repaymentFrequencyType" => p["repaymentFrequencyType"],
      "transactionProcessingStrategyCode" => p["transactionProcessingStrategyCode"],
      "amortizationType" => p["amortizationType"],
      "interestRatePerPeriod" => p["interestRatePerPeriod"],
      "interestRateFrequencyType" => p["interestRateFrequencyType"],
      "annualInterestRate" => p["annualInterestRate"],
      "interestType" => p["interestType"],
      "isFloatingInterestRate" => p["isFloatingInterestRateCalculationAllowed"],
      "interestCalculationPeriodType" => p["interestCalculationPeriodType"],
      "allowPartialPeriodInterestCalculation" => p["allowPartialPeriodInterestCalculation"],
      "graceOnPrincipalPayment" => p["graceOnPrincipalPayment"],
      "recurringMoratoriumOnPrincipalPeriods" => p["recurringMoratoriumOnPrincipalPeriods"],
      "graceOnInterestPayment" => p["graceOnInterestPayment"],
      "graceOnInterestCharged" => p["graceOnInterestCharged"],
      "charges" => loan_charges,
      "multiDisburseLoan" => p["multiDisburseLoan"],
      "canDefineInstallmentAmount" => p["canDefineInstallmentAmount"],
      "product" => p,
      "graceOnArrearsAgeing" => p["graceOnArrearsAgeing"],
      "overdueCharges" => overdue,
      "daysInMonthType" => p["daysInMonthType"],
      "daysInYearType" => p["daysInYearType"],
      "isInterestRecalculationEnabled" => p["isInterestRecalculationEnabled"],
      "interestRecalculationData" => %{},
      "isVariableInstallmentsAllowed" => p["allowVariableInstallments"],
      "minimumGap" => p["minimumGap"],
      "maximumGap" => p["maximumGap"],
      "isEqualAmortization" => p["isEqualAmortization"],
      "disallowExpectedDisbursements" => p["disallowExpectedDisbursements"],
      "delinquent" => delinquent(),
      "repaymentStartDateType" => p["repaymentStartDateType"],
      "interestRecognitionOnDisbursementDate" => p["interestRecognitionOnDisbursementDate"],
      "loanScheduleType" => p["loanScheduleType"],
      "loanScheduleProcessingType" => p["loanScheduleProcessingType"],
      "chargeOptions" => charge_options(p["multiDisburseLoan"]),
      "fundOptions" => Enum.map(Funds.list(), &fund/1),
      "loanPurposeOptions" => purposes(),
      "loanCollateralOptions" => collateral_options()
    }
    |> Map.merge(Map.take(static, option_names()))
    |> Map.put("clientActiveLoanOptions", nil)
    |> Map.put("loanScheduleTypeOptions", static["loanScheduleTypeOptions"])
    |> reject_nil()
  end

  defp option_names do
    ~w(termFrequencyTypeOptions repaymentFrequencyTypeOptions repaymentFrequencyNthDayTypeOptions
       repaymentFrequencyDaysOfWeekTypeOptions interestRateFrequencyTypeOptions amortizationTypeOptions
       interestTypeOptions interestCalculationPeriodTypeOptions transactionProcessingStrategyOptions
       loanScheduleTypeOptions loanScheduleProcessingTypeOptions daysInYearCustomStrategyOptions)
  end

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  # a product's charge as the loan that takes it would carry it
  defp loan_charge(c, p) do
    percent? = c["chargeCalculationType"]["id"] in [2, 3, 4]

    %{
      "chargeId" => c["id"],
      "name" => c["name"],
      "chargeTimeType" => c["chargeTimeType"],
      "chargeCalculationType" => c["chargeCalculationType"],
      "percentage" => if(percent?, do: c["amount"]),
      "currency" => Map.delete(p["currency"], "inMultiplesOf"),
      "amount" => c["amount"],
      "amountPaid" => 0,
      "amountWaived" => 0,
      "amountWrittenOff" => 0,
      "amountOutstanding" => c["amount"],
      "amountOrPercentage" => c["amount"],
      "penalty" => c["penalty"],
      "chargePaymentMode" => c["chargePaymentMode"],
      "paid" => false,
      "waived" => false,
      "chargePayable" => false
    }
    |> reject_nil()
  end

  @doc "The fees and penalties a loan can take in a currency, by name."
  @spec charge_options_in(String.t()) :: [map]
  def charge_options_in(currency),
    do: Enum.filter(charge_options(nil), &(&1["currency"]["code"] == currency))

  # the fees and penalties a loan can take, but not the ones a loan only gets when it is overdue or by tranche
  defp charge_options(_multi?) do
    (Catalog.applicable_to_loans(false) ++ Catalog.applicable_to_loans(true))
    |> Enum.reject(&(&1.time in [9, 10]))
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&(&1 |> Charges.charge_json() |> Map.delete("overdueInstallmentCharge")))
  end

  defp fund(f), do: %{"id" => f.id, "name" => f.name, "externalId" => f.external_id}

  defp purposes, do: code_values("LoanPurpose")
  defp collateral_options, do: code_values("LoanCollateral")

  defp code_values(name) do
    case Codes.get_by_name(name) do
      {:ok, code} ->
        for v <- Codes.values(code.id),
            do: %{
              "id" => v.id,
              "name" => v.name,
              "description" => v.description,
              "position" => v.position,
              "active" => v.active,
              "mandatory" => v.mandatory
            }

      {:error, _} ->
        []
    end
  end

  defp delinquent do
    for k <-
          ~w(availableDisbursementAmount availableDisbursementAmountWithOverApplied pastDueDays
             nextPaymentAmount delinquentDays delinquentAmount lastPaymentAmount lastRepaymentAmount
             delinquentPrincipal delinquentInterest delinquentFee delinquentPenalty),
        into: %{},
        do: {k, 0}
  end
end
