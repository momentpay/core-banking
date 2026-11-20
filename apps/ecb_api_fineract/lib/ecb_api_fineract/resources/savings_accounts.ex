defmodule ECBApiFineract.Resources.SavingsAccounts do
  @moduledoc """
  `/v1/savingsaccounts`: savings accounts. A page of them, one account, the template an application is made
  from, applying, changing and deleting an application, and the commands that take it from application to an
  active account and on to closed. Answers as Fineract's `SavingsAccountsApiResource` does.
  """
  alias ECBApiFineract.Errors

  alias ECBApiFineract.Resources.{
    Charges,
    Read,
    SavingsAccountCharges,
    SavingsTransactions,
    Write
  }

  alias ECBCatalog.Charges, as: CatalogCharges
  alias ECBDeposits.{Savings, SavingsEnums, SavingsProducts}
  alias ECBDeposits.Savings.Charges, as: AccountCharges
  alias ECBParty.Clients
  alias ECBPlatform.Errors.{DomainRuleViolation, UnrecognizedQueryParameter}

  @resource "SAVINGSACCOUNT"

  # `command=` (compared without regard to case) and the action it runs
  @commands %{
    "reject" => "REJECT",
    "withdrawnbyapplicant" => "WITHDRAW",
    "approve" => "APPROVE",
    "undoapproval" => "APPROVALUNDO",
    "activate" => "ACTIVATE",
    "close" => "CLOSE",
    "calculateinterest" => "CALCULATEINTEREST",
    "postinterest" => "POSTINTEREST"
  }

  # what Fineract has besides: refused, not taken for unknown ones
  @not_built ~w(assignsavingsofficer unassignsavingsofficer blockdebit unblockdebit
                blockcredit unblockcredit block unblock)

  # what Fineract lists as the commands it knows, in its order
  @command_names ~w(reject withdrawnByApplicant approve undoapproval activate calculateInterest postInterest close
                    assignSavingsOfficer unassignSavingsOfficer blockDebit unblockDebit blockCredit unblockCredit
                    block unblock)

  # --- reads ----------------------------------------------------------------------------------

  @doc "`GET /savingsaccounts`"
  def index(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      {total, rows} =
        Savings.list(
          external_id: q["externalId"],
          client_id: Read.int_param(q, "clientId"),
          account_no: q["accountNo"],
          order_by: q["orderBy"],
          sort: q["sortOrder"],
          limit: Read.int_param(q, "limit"),
          offset: Read.int_param(q, "offset")
        )

      users = Savings.users(Enum.flat_map(rows, &user_ids/1))
      %{"totalFilteredRecords" => total, "pageItems" => Enum.map(rows, &list_item(&1, users))}
    end)
  end

  @doc "`GET /savingsaccounts/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> id |> Savings.fetch!() |> one(conn.query_params) end)
    end)
  end

  @doc "`GET /savingsaccounts/external-id/:external_id`"
  def show_by_external_id(conn, external_id) do
    Read.respond(conn, @resource, fn ->
      case Savings.get_by_external_id(external_id) do
        nil -> {:error, Savings.not_found_by_external_id(external_id)}
        account -> one(account, conn.query_params)
      end
    end)
  end

  defp one(a, q),
    do:
      a
      |> list_item(Savings.users(user_ids(a)))
      |> with_detail(a)
      |> with_associations(a, associations(q["associations"]))

  # `associations=`: the transactions come with `transactions` and with `all`
  defp associations(nil), do: []
  defp associations(text), do: text |> String.split(",") |> Enum.map(&String.trim/1)

  defp with_associations(body, a, associations) do
    list =
      if Enum.any?(associations, &(&1 in ["transactions", "all"])),
        do: SavingsTransactions.list_json(a),
        else: []

    # an account without a transaction has no list of them to show
    body =
      if list == [],
        do: body,
        else:
          Map.merge(body, %{
            "transactions" => list,
            "savingsAccountTransactionsWithPivotConfig" => list
          })

    charges = AccountCharges.list(a.id)

    if charges != [] and Enum.any?(associations, &(&1 in ["charges", "all"])),
      do:
        body
        |> Map.put("charges", Enum.map(charges, &SavingsAccountCharges.account_json(&1, a)))
        |> put_fee("withdrawalFee", Enum.filter(charges, &AccountCharges.withdrawal_fee?/1), a)
        |> put_fee("annualFee", Enum.filter(charges, &AccountCharges.annual?/1), a),
      else: body
  end

  # the account names its annual fee and a withdrawal fee (the last it has) beside its charges
  defp put_fee(body, _key, [], _a), do: body

  defp put_fee(body, key, charges, a),
    do: Map.put(body, key, SavingsAccountCharges.account_json(List.last(charges), a))

  # what the page leaves out: the longer summary, the ids of the choices, and what depends on the account having
  # been activated
  defp with_detail(body, a) do
    body
    |> Map.update!("summary", fn summary ->
      Map.merge(summary, %{
        "runningBalanceOnPivotDate" => 0,
        "runningBalanceOnInterestPostingTillDate" => 0
      })
    end)
    |> Map.merge(%{
      "interestPostingPeriodTypeId" => a.interest_posting_period_enum,
      "newSavingsAccountTransactionData" => [],
      "existingReversedTransactionIds" => [],
      "interestCalculationDaysInYearTypeId" => a.interest_calculation_days_in_year_type_enum,
      "savingsAccountTransactionData" => [],
      "interestCalculationTypeId" => a.interest_calculation_type_enum,
      "interestCompoundingPeriodTypeId" => a.interest_compounding_period_enum,
      "startInterestCalculationDate" => a.start_interest_calculation_date,
      "cashBasedAccountingEnabledOnSavingsProduct" => false,
      "accrualBasedAccountingEnabledOnSavingsProduct" => false,
      "depositTypeId" => 100,
      "lockinPeriodFrequencyTypeId" =>
        a.lockin_period_frequency && a.lockin_period_frequency_enum,
      "existingTransactionIds" => [],
      "activationLocalDate" => a.activatedon_date
    })
  end

  defp user_ids(a),
    do: [
      a.submittedon_userid,
      a.approvedon_userid,
      a.rejectedon_userid,
      a.withdrawnon_userid,
      a.activatedon_userid,
      a.closedon_userid
    ]

  defp list_item(a, users) do
    %{
      "id" => a.id,
      "accountNo" => a.account_no,
      "depositType" => SavingsEnums.deposit_type(),
      "externalId" => a.external_id,
      "clientId" => a.client_id,
      "clientName" => a.client_name,
      "savingsProductId" => a.product_id,
      "savingsProductName" => a.product_name,
      "fieldOfficerId" => a.field_officer_id || 0,
      "fieldOfficerName" => a.field_officer_name,
      "status" => SavingsEnums.account_status(a.status_enum),
      "subStatus" => SavingsEnums.sub_status_none(),
      "timeline" => timeline(a, users),
      "currency" => currency(a),
      "nominalAnnualInterestRate" => a.nominal_annual_interest_rate,
      "interestCompoundingPeriodType" =>
        option(SavingsEnums.compounding(a.interest_compounding_period_enum)),
      "interestPostingPeriodType" => option(SavingsEnums.posting(a.interest_posting_period_enum)),
      "interestCalculationType" =>
        option(SavingsEnums.calculation(a.interest_calculation_type_enum)),
      "interestCalculationDaysInYearType" =>
        option(SavingsEnums.days_in_year(a.interest_calculation_days_in_year_type_enum)),
      "minRequiredOpeningBalance" => nonzero(a.min_required_opening_balance),
      "lockinPeriodFrequency" => whole(a.lockin_period_frequency),
      "lockinPeriodFrequencyType" =>
        a.lockin_period_frequency && option(SavingsEnums.lockin(a.lockin_period_frequency_enum)),
      "withdrawalFeeForTransfers" => a.withdrawal_fee_for_transfer == true,
      "allowOverdraft" => a.allow_overdraft == true,
      "overdraftLimit" => nonzero(a.overdraft_limit),
      "nominalAnnualInterestRateOverdraft" => nonzero(a.nominal_annual_interest_rate_overdraft),
      "minOverdraftForInterestCalculation" => nonzero(a.min_overdraft_for_interest_calculation),
      "minRequiredBalance" => nonzero(a.min_required_balance),
      "enforceMinRequiredBalance" => a.enforce_min_required_balance == true,
      "minBalanceForInterestCalculation" => nonzero(a.min_balance_for_interest_calculation),
      "lienAllowed" => a.is_lien_allowed == true,
      "maxAllowedLienLimit" => nonzero(a.max_allowed_lien_limit),
      "withHoldTax" => a.withhold_tax == true,
      "lastActiveTransactionDate" =>
        a.activatedon_date && (a.last_transaction_date || a.activatedon_date),
      "isDormancyTrackingActive" => a.dormancy_tracking_active == true,
      "summary" => summary(a)
    }
  end

  defp whole(nil), do: nil
  defp whole(%Decimal{} = d), do: Decimal.to_integer(d)

  # a total that is nothing is written as `0`, one that is something with its decimals
  defp whole_zero(nil), do: 0
  defp whole_zero(%Decimal{} = d), do: if(Decimal.eq?(d, 0), do: 0, else: d)

  # Fineract leaves out an overdraft term that is zero
  defp nonzero(nil), do: nil
  defp nonzero(%Decimal{} = d), do: if(Decimal.eq?(d, 0), do: nil, else: d)

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  @doc false
  def currency(a) do
    Charges.currency(%{
      code: a.currency_code,
      name: a.currency_name,
      decimal_places: a.currency_digits,
      multiples_of: a.currency_multiplesof,
      display_symbol: a.currency_symbol,
      name_code: a.currency_name_code
    })
    |> Map.delete("inMultiplesOf")
  end

  defp summary(a) do
    balance = a.account_balance_derived
    on_hold = a.on_hold_funds_derived || Decimal.new(0)
    earned = nonzero(a.total_interest_earned_derived)
    posted = a.total_interest_posted_derived || Decimal.new(0)
    overdraft_interest = a.total_overdraft_interest_derived || Decimal.new(0)

    %{
      "currency" => currency(a),
      "totalDeposits" => nonzero(a.total_deposits_derived),
      "totalWithdrawals" => nonzero(a.total_withdrawals_derived),
      "totalWithdrawalFees" => nonzero(a.total_withdrawal_fees_derived),
      "totalAnnualFees" => nonzero(a.total_annual_fees_derived),
      "totalFeeCharge" => nonzero(a.total_fees_charge_derived),
      "totalPenaltyCharge" => nonzero(a.total_penalty_charge_derived),
      "totalInterestEarned" => earned,
      "totalInterestPosted" => whole_zero(a.total_interest_posted_derived),
      "accountBalance" => balance,
      "totalOverdraftInterestDerived" => whole_zero(a.total_overdraft_interest_derived),
      "interestNotPosted" =>
        if(earned, do: earned |> Decimal.sub(posted) |> Decimal.add(overdraft_interest), else: 0),
      "lastInterestCalculationDate" => earned && a.last_interest_calculation_date,
      "interestPostedTillDate" => a.interest_posted_till_date,
      "availableBalance" => Decimal.sub(balance, on_hold)
    }
  end

  defp timeline(a, users) do
    %{"submittedOnDate" => a.submittedon_date}
    |> person("submittedBy", users[a.submittedon_userid])
    |> dated("rejectedOnDate", a.rejectedon_date)
    |> person("rejectedBy", a.rejectedon_date && users[a.rejectedon_userid])
    |> dated("withdrawnOnDate", a.withdrawnon_date)
    |> person("withdrawnBy", a.withdrawnon_date && users[a.withdrawnon_userid])
    |> dated("approvedOnDate", a.approvedon_date)
    |> person("approvedBy", a.approvedon_date && users[a.approvedon_userid])
    |> dated("activatedOnDate", a.activatedon_date)
    |> person("activatedBy", a.activatedon_date && users[a.activatedon_userid])
    |> dated("closedOnDate", a.closedon_date)
    |> person("closedBy", a.closedon_date && users[a.closedon_userid])
  end

  defp dated(map, key, date), do: Map.put(map, key, date)

  defp person(map, _prefix, nil), do: map

  defp person(map, prefix, user) do
    map
    |> Map.put(prefix <> "Username", user.username)
    |> Map.put(prefix <> "Firstname", user.firstname)
    |> Map.put(prefix <> "Lastname", user.lastname)
  end

  # --- the template ---------------------------------------------------------------------------

  @doc "`GET /savingsaccounts/template`"
  def template(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      client_id = Read.int_param(q, "clientId")
      product_id = Read.int_param(q, "productId")

      with {:ok, client} <- template_client(client_id),
           {:ok, product} <- template_product(product_id) do
        client
        |> Map.merge(product)
        |> Map.put("productOptions", Enum.map(SavingsProducts.list(), &product_option/1))
        |> Map.merge(options(product_id))
      end
    end)
  end

  defp template_client(nil), do: {:ok, %{}}

  defp template_client(id) do
    client = Clients.fetch!(id)
    {:ok, %{"clientId" => client.id, "clientName" => client.display_name}}
  end

  # without a product the template says what a product of no particular kind would
  defp template_product(nil) do
    {:ok,
     %{
       "nominalAnnualInterestRate" => 0,
       "withdrawalFeeForTransfers" => false,
       "allowOverdraft" => false,
       "enforceMinRequiredBalance" => false,
       "lienAllowed" => false,
       "withHoldTax" => false,
       "isDormancyTrackingActive" => false
     }}
  end

  defp template_product(id) do
    with {:ok, p} <- SavingsProducts.get(id) do
      {:ok,
       %{
         "savingsProductId" => p.id,
         "savingsProductName" => p.name,
         "timeline" => %{},
         "currency" => Charges.currency(p.currency),
         "nominalAnnualInterestRate" => p.nominal_annual_interest_rate,
         "interestCompoundingPeriodType" => option(p.compounding),
         "interestPostingPeriodType" => option(p.posting),
         "interestCalculationType" => option(p.calculation),
         "interestCalculationDaysInYearType" => option(p.days_in_year),
         "minRequiredOpeningBalance" => nonzero(p.min_required_opening_balance),
         "lockinPeriodFrequency" => p.lockin_period_frequency,
         "lockinPeriodFrequencyType" => option(p.lockin_type),
         "withdrawalFeeForTransfers" => p.withdrawal_fee_for_transfers == true,
         "allowOverdraft" => p.allow_overdraft == true,
         "overdraftLimit" => nonzero(p.overdraft_limit),
         "minRequiredBalance" => nonzero(p.min_required_balance),
         "enforceMinRequiredBalance" => p.enforce_min_required_balance == true,
         "lienAllowed" => p.lien_allowed == true,
         "withHoldTax" => p.withhold_tax == true,
         "isDormancyTrackingActive" => p.dormancy_tracking_active == true,
         "nominalAnnualInterestRateOverdraft" =>
           nonzero(p.nominal_annual_interest_rate_overdraft),
         "charges" => Enum.map(CatalogCharges.for_savings_product(id), &charge/1)
       }}
    end
  end

  defp product_option(p) do
    %{
      "id" => p.id,
      "name" => p.name,
      "withdrawalFeeForTransfers" => p.withdrawal_fee_for_transfers == true,
      "allowOverdraft" => false,
      "enforceMinRequiredBalance" => p.enforce_min_required_balance == true,
      "lienAllowed" => p.lien_allowed == true,
      "withHoldTax" => p.withhold_tax == true
    }
  end

  defp charge(c), do: c |> Charges.charge_json() |> Map.delete("overdueInstallmentCharge")

  # the choices are only given once a product is chosen
  defp options(nil), do: %{"chargeOptions" => []}

  defp options(_product_id) do
    %{
      "interestCompoundingPeriodTypeOptions" =>
        Enum.map(SavingsEnums.compounding(), &Read.option/1),
      "interestPostingPeriodTypeOptions" => Enum.map(SavingsEnums.posting(), &Read.option/1),
      "interestCalculationTypeOptions" => Enum.map(SavingsEnums.calculation(), &Read.option/1),
      "interestCalculationDaysInYearTypeOptions" =>
        Enum.map(SavingsEnums.days_in_year(), &Read.option/1),
      "lockinPeriodFrequencyTypeOptions" => Enum.map(SavingsEnums.lockin(), &Read.option/1),
      "withdrawalFeeTypeOptions" => Enum.map(SavingsEnums.withdrawal_fee(), &Read.option/1),
      "chargeOptions" => Enum.map(CatalogCharges.applicable_to_savings(false), &charge/1)
    }
  end

  # --- writes ---------------------------------------------------------------------------------

  @doc "`POST /savingsaccounts`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /savingsaccounts/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /savingsaccounts/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  @doc "`POST /savingsaccounts/:id?command=...`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      command = conn.query_params["command"]
      key = command && String.downcase(command)

      cond do
        Map.has_key?(@commands, key) ->
          Write.execute(conn, @resource, Map.fetch!(@commands, key), id: id)

        key in @not_built ->
          Errors.render(conn, %DomainRuleViolation{
            code: "error.msg.savingsaccount.feature.not.supported.yet",
            message: "The savings account command #{command} is not supported yet by E-CoreBank",
            args: [command]
          })

        true ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: command,
            allowed: @command_names
          })
      end
    end)
  end
end
