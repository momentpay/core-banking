defmodule ECBApiFineract.Resources.FixedDepositAccounts do
  @moduledoc """
  `/v1/fixeddepositaccounts`: fixed deposit accounts. The list, one account (with `associations`), the template for
  an application, applying, changing and deleting an application, and the commands that take an application to an
  active account. Answers as Fineract's `FixedDepositAccountsApiResource` does.
  """
  alias ECBApiFineract.{Errors, Response}

  alias ECBApiFineract.Resources.{
    Charges,
    PaymentTypes,
    Read,
    SavingsAccounts,
    SavingsProducts,
    SavingsTransactions,
    Write
  }

  alias ECBDeposits.{DepositAccounts, DepositEnums, DepositProducts, Savings, SavingsEnums}
  alias ECBDeposits.DepositAccounts.Closing
  alias ECBOrg.PaymentTypes, as: OrgPaymentTypes
  alias ECBParty.Clients
  alias ECBPlatform.Errors.UnrecognizedQueryParameter
  alias ECBPlatform.{Params, Security, TenantRepo}

  @resource "FIXEDDEPOSITACCOUNT"

  @commands %{
    "reject" => "REJECT",
    "withdrawnbyapplicant" => "WITHDRAW",
    "approve" => "APPROVE",
    "undoapproval" => "APPROVALUNDO",
    "activate" => "ACTIVATE",
    "calculateinterest" => "CALCULATEINTEREST",
    "postinterest" => "POSTINTEREST",
    "close" => "CLOSE",
    "prematureclose" => "PREMATURECLOSE"
  }

  @command_names ~w(reject withdrawnByApplicant approve undoapproval activate calculateInterest postInterest close
                    prematureClose calculatePrematureAmount)

  # --- reads ------------------------------------------------------------------------------------------

  @doc "`GET /fixeddepositaccounts`"
  def index(conn) do
    Read.respond(conn, @resource, fn ->
      q = conn.query_params

      accounts =
        :fixed
        |> DepositAccounts.list()
        |> page(Read.int_param(q, "offset"), Read.int_param(q, "limit"))

      users = Savings.users(Enum.flat_map(accounts, &SavingsAccounts.user_ids/1))
      Enum.map(accounts, &list_item(&1, users))
    end)
  end

  defp page(accounts, offset, limit) do
    accounts = Enum.drop(accounts, offset || 0)
    if limit, do: Enum.take(accounts, limit), else: accounts
  end

  @doc "`GET /fixeddepositaccounts/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        id |> then(&DepositAccounts.fetch!(:fixed, &1)) |> one(conn.query_params)
      end)
    end)
  end

  defp one(a, q) do
    users = Savings.users(SavingsAccounts.user_ids(a))

    a
    |> list_item(users)
    |> Map.put("activationCharge", 0)
    |> Map.put("accountChart", chart_json(DepositAccounts.chart(a.id), a))
    |> with_associations(a, associations(q["associations"]))
    |> with_template(a, q["template"] == "true")
  end

  defp associations(nil), do: []
  defp associations(text), do: text |> String.split(",") |> Enum.map(&String.trim/1)

  defp with_associations(body, a, associations) do
    if "all" in associations or "transactions" in associations do
      case SavingsTransactions.compact_list_json(a) do
        [] ->
          body

        transactions ->
          Map.put(body, "transactions", Enum.map(transactions, &with_multiples(&1, a)))
      end
    else
      body
    end
  end

  # a deposit's transactions know nothing of reversals or holds, and show the multiple of their currency
  defp with_multiples(transaction, a) do
    transaction
    |> Map.drop(~w(isReversal originalTransactionId releaseTransactionId reasonForBlock))
    |> Map.update!("currency", &Map.put(&1, "inMultiplesOf", a.currency_multiplesof))
  end

  defp with_template(body, _a, false), do: body

  defp with_template(body, a, true) do
    body
    |> Map.merge(options())
    |> Map.merge(Map.delete(product_choices(), "maturityInstructionOptions"))
    |> Map.put("productOptions", Enum.map(DepositProducts.list(:fixed), &product_option/1))
    |> Map.put("savingsAccounts", [])
    |> Map.put("chargeOptions", charge_options(a.product_id))
  end

  defp list_item(a, users) do
    t = a.term

    %{
      "preClosurePenalApplicable" => t.pre_closure_penal_applicable == true,
      "preClosurePenalInterest" => t.pre_closure_penal_interest,
      "preClosurePenalInterestOnType" =>
        option(DepositEnums.pre_closure_on(t.pre_closure_penal_interest_on)),
      "minDepositTerm" => t.min_deposit_term,
      "maxDepositTerm" => t.max_deposit_term,
      "minDepositTermType" => option(DepositEnums.term_unit(t.min_deposit_term_type)),
      "maxDepositTermType" => option(DepositEnums.term_unit(t.max_deposit_term_type)),
      "inMultiplesOfDepositTerm" => t.in_multiples_of_deposit_term,
      "inMultiplesOfDepositTermType" =>
        option(DepositEnums.term_unit(t.in_multiples_of_deposit_term_type)),
      "depositAmount" => t.deposit_amount,
      "maturityAmount" => t.maturity_amount,
      "maturityDate" => t.maturity_date,
      "depositPeriod" => t.deposit_period,
      "depositPeriodFrequency" => option(period_frequency(t.deposit_period_frequency)),
      "transferInterestToSavings" => t.transfer_interest == true,
      "onAccountClosure" => option(DepositEnums.maturity_instruction(t.on_closure)),
      "id" => a.id,
      "accountNo" => a.account_no,
      "externalId" => a.external_id,
      "clientId" => a.client_id,
      "clientName" => a.client_name,
      "depositProductId" => a.product_id,
      "depositProductName" => a.product_name,
      "fieldOfficerId" => a.field_officer_id || 0,
      "status" => SavingsEnums.account_status(a.status_enum),
      "timeline" =>
        a
        |> SavingsAccounts.timeline(users)
        |> Map.drop(~w(activatedByUsername activatedByFirstname activatedByLastname)),
      "currency" => Charges.currency(currency(a)),
      "nominalAnnualInterestRate" => a.nominal_annual_interest_rate,
      "interestCompoundingPeriodType" =>
        option(SavingsEnums.compounding(a.interest_compounding_period_enum)),
      "interestPostingPeriodType" => option(SavingsEnums.posting(a.interest_posting_period_enum)),
      "interestCalculationType" =>
        option(SavingsEnums.calculation(a.interest_calculation_type_enum)),
      "interestCalculationDaysInYearType" =>
        option(SavingsEnums.days_in_year(a.interest_calculation_days_in_year_type_enum)),
      "withdrawalFeeForTransfers" => a.withdrawal_fee_for_transfer == true,
      "depositType" => %{
        "id" => 200,
        "code" => "depositAccountType.fixedDeposit",
        "value" => "Fixed Deposit"
      },
      "withHoldTax" => a.withhold_tax == true,
      "summary" => summary(a)
    }
    |> maybe_lockin(a)
  end

  # the lock-in period of the account, when it has one
  defp maybe_lockin(body, %{lockin_period_frequency: nil}), do: body

  defp maybe_lockin(body, a) do
    body
    |> Map.put(
      "lockinPeriodFrequency",
      ECBDeposits.SavingsProducts.whole(a.lockin_period_frequency)
    )
    |> Map.put(
      "lockinPeriodFrequencyType",
      option(SavingsEnums.lockin(a.lockin_period_frequency_enum))
    )
  end

  defp currency(a) do
    %{
      code: a.currency_code,
      name: a.currency_name,
      decimal_places: a.currency_digits,
      multiples_of: a.currency_multiplesof,
      display_symbol: a.currency_symbol,
      name_code: a.currency_name_code
    }
  end

  # the deposit's own period units
  defp period_frequency(nil), do: nil

  defp period_frequency(id) do
    case Enum.find(DepositEnums.term_units(), &(&1.id == id)) do
      nil -> nil
      u -> %{u | code: String.replace(u.code, "deposit.term.", "deposit.period.")}
    end
  end

  # a deposit's summary has no available balance and no overdraft figures
  defp summary(a) do
    a
    |> SavingsAccounts.summary()
    |> Map.drop([
      "availableBalance",
      "interestNotPosted",
      "lastInterestCalculationDate",
      "totalOverdraftInterestDerived",
      "totalWithdrawalFees",
      "totalAnnualFees",
      "totalFeeCharge",
      "totalPenaltyCharge"
    ])
    |> Map.update!("currency", &Map.put(&1, "inMultiplesOf", a.currency_multiplesof))
    |> without_zero("totalInterestPosted")
  end

  defp without_zero(map, key) do
    case Map.get(map, key) do
      zero when zero in [0, nil] -> Map.delete(map, key)
      %Decimal{} = d -> if Decimal.eq?(d, 0), do: Map.delete(map, key), else: map
      _ -> map
    end
  end

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  # --- the chart of an account ---------------------------------------------------------------------------

  defp chart_json(nil, _a), do: nil

  defp chart_json(chart, a) do
    %{
      "id" => chart.id,
      "name" => chart.name,
      "description" => chart.description,
      "fromDate" => chart.from_date,
      "endDate" => chart.end_date,
      "isPrimaryGroupingByAmount" => chart.grouping == true,
      "accountId" => a.id,
      "accountNumber" => a.account_no,
      "chartSlabs" => Enum.map(chart.slabs, &slab_json(&1, a)),
      "periodTypes" => Enum.map(DepositEnums.chart_periods(), &Read.option/1)
    }
  end

  defp slab_json(slab, a) do
    %{
      "id" => slab.id,
      "description" => slab.description,
      "periodType" => option(DepositEnums.chart_period(slab.period_type)),
      "fromPeriod" => slab.from_period,
      "toPeriod" => slab.to_period,
      "amountRangeFrom" => slab.amount_from,
      "amountRangeTo" => slab.amount_to,
      "annualInterestRate" => slab.rate,
      "currency" => a |> currency() |> Charges.currency() |> Map.delete("inMultiplesOf")
    }
  end

  # --- the template -----------------------------------------------------------------------------------

  @doc "`GET /fixeddepositaccounts/template`"
  def template(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      client_id = Read.int_param(q, "clientId")
      product_id = Read.int_param(q, "productId")

      with {:ok, client} <- template_client(client_id),
           {:ok, product} <- template_product(product_id) do
        template_body(client, product, product_id)
      end
    end)
  end

  defp template_body(client, product, product_id) do
    %{
      "preClosurePenalApplicable" => false,
      "withdrawalFeeForTransfers" => false,
      "depositType" => %{
        "id" => 200,
        "code" => "depositAccountType.fixedDeposit",
        "value" => "Fixed Deposit"
      },
      "withHoldTax" => false
    }
    |> Map.merge(client)
    |> Map.merge(product)
    |> Map.merge(options())
    |> Map.merge(if product_id, do: product_choices(), else: %{})
    |> Map.put("productOptions", Enum.map(DepositProducts.list(:fixed), &product_option/1))
    |> Map.put("chargeOptions", charge_options(product_id))
  end

  defp template_client(nil), do: {:ok, %{}}

  defp template_client(id) do
    client = Clients.fetch!(id)
    {:ok, %{"clientId" => client.id, "clientName" => client.display_name}}
  end

  defp template_product(nil), do: {:ok, %{}}

  # a product that is not there ends in an unhandled error in Fineract's template
  defp template_product(id) do
    with {:ok, p} <- unhandled(DepositProducts.get(:fixed, id)) do
      {:ok,
       %{
         "preClosurePenalApplicable" => p[:pre_closure_penal_applicable] == true,
         "preClosurePenalInterest" => p[:pre_closure_penal_interest],
         "preClosurePenalInterestOnType" =>
           option(DepositEnums.pre_closure_on(p[:pre_closure_penal_interest_on])),
         "minDepositTerm" => p[:min_deposit_term],
         "maxDepositTerm" => p[:max_deposit_term],
         "minDepositTermType" => option(DepositEnums.term_unit(p[:min_deposit_term_type])),
         "maxDepositTermType" => option(DepositEnums.term_unit(p[:max_deposit_term_type])),
         "inMultiplesOfDepositTerm" => p[:in_multiples_of_deposit_term],
         "inMultiplesOfDepositTermType" =>
           option(DepositEnums.term_unit(p[:in_multiples_of_deposit_term_type])),
         "transferInterestToSavings" => false,
         "savingsAccounts" => [],
         "depositProductId" => p.id,
         "depositProductName" => p.name,
         "timeline" => %{},
         "currency" => Charges.currency(p.currency),
         "nominalAnnualInterestRate" => p.nominal_annual_interest_rate,
         "interestCompoundingPeriodType" => option(p.compounding),
         "interestPostingPeriodType" => option(p.posting),
         "interestCalculationType" => option(p.calculation),
         "interestCalculationDaysInYearType" => option(p.days_in_year),
         "withdrawalFeeForTransfers" => p.withdrawal_fee_for_transfers == true,
         "depositType" => %{
           "id" => 200,
           "code" => "depositAccountType.fixedDeposit",
           "value" => "Fixed Deposit"
         },
         "withHoldTax" => p.withhold_tax == true,
         "charges" => [],
         "accountChart" => product_chart(DepositProducts.charts(p.id), p)
       }}
    end
  end

  defp unhandled({:error, _}), do: {:error, %ECBPlatform.Errors.ServerError{}}
  defp unhandled(ok), do: ok

  # the chart of the product in force today, as the template shows it
  defp product_chart(charts, p) do
    case ECBDeposits.InterestCharts.active(charts) do
      nil ->
        nil

      chart ->
        %{
          "name" => chart.name,
          "description" => chart.description,
          "fromDate" => chart.from_date,
          "isPrimaryGroupingByAmount" => chart.grouping == true,
          "chartSlabs" => Enum.map(chart.slabs, &template_slab(&1, p))
        }
        |> Map.merge(chart_options())
    end
  end

  defp template_slab(slab, p) do
    %{
      "periodType" => option(DepositEnums.chart_period(slab.period_type)),
      "fromPeriod" => slab.from_period,
      "toPeriod" => slab.to_period,
      "amountRangeFrom" => slab.amount_from,
      "amountRangeTo" => slab.amount_to,
      "annualInterestRate" => slab.rate,
      "currency" => Charges.currency(p.currency) |> Map.delete("inMultiplesOf"),
      "incentives" => []
    }
  end

  defp chart_options do
    %{
      "periodTypes" => Enum.map(DepositEnums.chart_periods(), &Read.option/1),
      "entityTypeOptions" => Enum.map(DepositEnums.incentive_entities(), &Read.option/1),
      "attributeNameOptions" => Enum.map(DepositEnums.incentive_attributes(), &Read.option/1),
      "conditionTypeOptions" => Enum.map(DepositEnums.incentive_conditions(), &Read.option/1),
      "incentiveTypeOptions" => Enum.map(DepositEnums.incentive_types(), &Read.option/1),
      "genderOptions" => [],
      "clientTypeOptions" => [],
      "clientClassificationOptions" => []
    }
  end

  # the choices that are always there, and those that come once a product is chosen
  defp options do
    %{
      "preClosurePenalInterestOnTypeOptions" =>
        Enum.map(DepositEnums.pre_closure_on(), &Read.option/1),
      "periodFrequencyTypeOptions" => Enum.map(DepositEnums.frequency_options(), &Read.option/1)
    }
  end

  defp product_choices do
    %{
      "maturityInstructionOptions" =>
        Enum.map(DepositEnums.maturity_instructions(), &Read.option/1),
      "interestCompoundingPeriodTypeOptions" =>
        Enum.map(SavingsEnums.compounding(), &Read.option/1),
      "interestPostingPeriodTypeOptions" => Enum.map(SavingsEnums.posting(), &Read.option/1),
      "interestCalculationTypeOptions" => Enum.map(SavingsEnums.calculation(), &Read.option/1),
      "interestCalculationDaysInYearTypeOptions" =>
        Enum.map(SavingsEnums.days_in_year(), &Read.option/1),
      "lockinPeriodFrequencyTypeOptions" => Enum.map(SavingsEnums.lockin(), &Read.option/1),
      "withdrawalFeeTypeOptions" => Enum.map(SavingsEnums.withdrawal_fee(), &Read.option/1)
    }
  end

  defp product_option(p),
    do: %{"id" => p.id, "name" => p.name, "withHoldTax" => p.withhold_tax == true}

  defp charge_options(_product_id) do
    ECBCatalog.Charges.applicable_to_savings(false) |> Enum.map(&SavingsProducts.charge/1)
  end

  # --- writes -------------------------------------------------------------------------------------------

  @doc "`POST /fixeddepositaccounts`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /fixeddepositaccounts/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /fixeddepositaccounts/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  @doc "`POST /fixeddepositaccounts/:id?command=...`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      command = conn.query_params["command"]
      key = command && command |> String.trim() |> String.downcase()

      cond do
        key == "calculateprematureamount" ->
          premature_amount(conn, id)

        Map.has_key?(@commands, key) ->
          Write.execute(conn, @resource, Map.fetch!(@commands, key), id: id)

        true ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: command,
            allowed: @command_names
          })
      end
    end)
  end

  # --- what closing early would pay, and the template of a closing -------------------------------------

  # Fineract asks nothing of the user but to be signed in
  defp premature_amount(conn, id) do
    body = if blank?(conn.assigns[:raw_body]), do: "{}", else: conn.assigns[:raw_body]

    case run(fn -> Closing.premature_amount!(id, Params.parse!(body)) end) do
      {:ok, %{account: account, amount: amount}} ->
        Response.json(conn, 200, %{
          "preClosurePenalApplicable" => false,
          "maturityAmount" => amount,
          "savingsAccounts" => active_savings(account),
          "onAccountClosureOptions" =>
            DepositEnums.maturity_instructions() |> Enum.take(2) |> Enum.map(&Read.option/1),
          "paymentTypeOptions" => payment_type_options(),
          "id" => account.id,
          "withdrawalFeeForTransfers" => false,
          "depositType" => deposit_type(),
          "withHoldTax" => false
        })

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  defp blank?(text), do: text == nil or String.trim(text) == ""

  defp run(fun) do
    case TenantRepo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: {:error, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp deposit_type,
    do: %{"id" => 200, "code" => "depositAccountType.fixedDeposit", "value" => "Fixed Deposit"}

  defp payment_type_options, do: Enum.map(OrgPaymentTypes.list(), &PaymentTypes.serialize/1)

  # the active savings accounts of the client of an account
  defp active_savings(account) do
    for s <- DepositAccounts.active_savings(account.client_id),
        do: %{"id" => s.id, "accountNo" => s.account_no, "productId" => s.product_id}
  end

  @doc "`GET /fixeddepositaccounts/:id/template`: with `command=close`, the account and the choices of closing it."
  def closing_template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      case Security.validate_has_read_permission(conn.assigns.current_user, @resource) do
        :ok -> closing_template(conn, id, conn.query_params["command"])
        {:error, error} -> Errors.render(conn, error)
      end
    end)
  end

  defp closing_template(conn, id, command) do
    if String.downcase(String.trim(command || "")) == "close",
      do: closing_template_body(conn, id),
      else: Plug.Conn.send_resp(conn, 204, "")
  end

  defp closing_template_body(conn, id) do
    Read.respond(conn, @resource, fn ->
      a = DepositAccounts.fetch!(:fixed, id)
      users = Savings.users(SavingsAccounts.user_ids(a))

      a
      |> list_item(users)
      |> Map.put("savingsAccounts", active_savings(a))
      |> Map.put(
        "onAccountClosureOptions",
        Enum.map(DepositEnums.maturity_instructions(), &Read.option/1)
      )
      |> Map.put("paymentTypeOptions", payment_type_options())
    end)
  end
end
