defmodule ECBApiFineract.Resources.RecurringDepositAccounts do
  @moduledoc """
  `/v1/recurringdepositaccounts`: recurring deposit accounts. The list, one account (with `associations`), the template
  for an application, applying, changing and deleting an application, and the commands that take an application to an
  active account. Answers as Fineract's `RecurringDepositAccountsApiResource` does, which includes showing the
  type of a recurring deposit as a fixed deposit. What follows activation is refused as not supported yet.
  """
  alias ECBApiFineract.Errors

  alias ECBApiFineract.Resources.{
    Charges,
    FixedDepositAccounts,
    Read,
    SavingsAccounts,
    Write
  }

  alias ECBDeposits.{DepositAccounts, DepositEnums, DepositProducts, Savings}
  alias ECBDeposits.DepositAccounts.Recurring
  alias ECBPlatform.Errors.UnrecognizedQueryParameter

  @resource "RECURRINGDEPOSITACCOUNT"

  @commands %{
    "reject" => "REJECT",
    "withdrawnbyapplicant" => "WITHDRAW",
    "approve" => "APPROVE",
    "undoapproval" => "APPROVALUNDO",
    "activate" => "ACTIVATE",
    "calculateinterest" => "CALCULATEINTEREST",
    "postinterest" => "POSTINTEREST",
    "close" => "CLOSE",
    "prematureclose" => "PREMATURECLOSE",
    "calculateprematureamount" => "CALCULATEPREMATUREAMOUNT",
    "updatedepositamount" => "UPDATEDEPOSITAMOUNT"
  }

  @command_names ~w(reject withdrawnByApplicant approve undoapproval activate calculateInterest postInterest close
                    prematureClose calculatePrematureAmount)

  # --- reads ------------------------------------------------------------------------------------------

  @doc "`GET /recurringdepositaccounts`"
  def index(conn) do
    Read.respond(conn, @resource, fn ->
      q = conn.query_params

      accounts =
        :recurring
        |> DepositAccounts.list()
        |> FixedDepositAccounts.page(Read.int_param(q, "offset"), Read.int_param(q, "limit"))

      users = Savings.users(Enum.flat_map(accounts, &SavingsAccounts.user_ids/1))
      Enum.map(accounts, &item(&1, users))
    end)
  end

  @doc "`GET /recurringdepositaccounts/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        id |> then(&DepositAccounts.fetch!(:recurring, &1)) |> one(conn.query_params)
      end)
    end)
  end

  defp one(a, q) do
    users = Savings.users(SavingsAccounts.user_ids(a))
    {type, every} = frequency(a.id)

    a
    |> item(users)
    |> Map.put("recurringFrequency", every)
    |> Map.put("recurringFrequencyType", option(frequency_type(type)))
    |> Map.put("accountChart", FixedDepositAccounts.chart_json(DepositAccounts.chart(a.id), a))
    |> FixedDepositAccounts.with_associations(
      a,
      FixedDepositAccounts.associations(q["associations"])
    )
    |> with_template(a, q["template"] == "true")
  end

  # the unit and the number the installments of the account fall due by, from its calendar
  defp frequency(id) do
    case Recurring.calendar(id) do
      nil -> {2, 1}
      %{recurrence: recurrence} -> Recurring.parse(recurrence)
    end
  end

  defp frequency_type(type) do
    unit = Enum.find(DepositEnums.term_units(), &(&1.id == type))

    %{
      unit
      | code:
          String.replace(
            unit.code,
            "deposit.term.savingsPeriodFrequencyType.",
            "recurring.deposit.frequency.periodFrequencyType."
          )
    }
  end

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  # an account the way Fineract lists it: that of a fixed deposit with the details of its installments, and none of the
  # fixed deposit's own
  defp item(a, users) do
    detail = DepositAccounts.recurring_detail(a.id)

    a
    |> FixedDepositAccounts.list_item(users)
    |> Map.delete("transferInterestToSavings")
    |> Map.merge(%{
      "mandatoryRecommendedDepositAmount" => detail.amount,
      "isMandatoryDeposit" => detail.mandatory == true,
      "allowWithdrawal" => detail.allow_withdrawal == true,
      "adjustAdvanceTowardsFuturePayments" => detail.adjust_advance == true,
      "isCalendarInherited" => detail.calendar_inherited == true
    })
    |> put_unless_nil("noOfOverdueInstallments", detail.overdue_installments)
    |> put_unless_zero("totalOverdueAmount", detail.overdue_amount)
    |> put_unless_nil("expectedFirstDepositOnDate", a.term.expected_first_deposit_on)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_unless_zero(map, _key, nil), do: map

  defp put_unless_zero(map, key, %Decimal{} = value),
    do: if(Decimal.eq?(value, 0), do: map, else: Map.put(map, key, value))

  defp with_template(body, _a, false), do: body

  defp with_template(body, a, true) do
    body
    |> Map.merge(FixedDepositAccounts.options())
    |> Map.merge(Map.delete(FixedDepositAccounts.product_choices(), "maturityInstructionOptions"))
    |> Map.put(
      "productOptions",
      Enum.map(DepositProducts.list(:recurring), &FixedDepositAccounts.product_option/1)
    )
    |> Map.put("chargeOptions", FixedDepositAccounts.charge_options(a.product_id))
  end

  # --- the template -----------------------------------------------------------------------------------

  @doc "`GET /recurringdepositaccounts/template`"
  def template(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      client_id = Read.int_param(q, "clientId")
      product_id = Read.int_param(q, "productId")

      with {:ok, client} <- FixedDepositAccounts.template_client(client_id),
           {:ok, product} <- template_product(product_id) do
        template_body(client, product, product_id)
      end
    end)
  end

  defp template_body(client, product, product_id) do
    %{
      "preClosurePenalApplicable" => false,
      "isMandatoryDeposit" => false,
      "allowWithdrawal" => false,
      "adjustAdvanceTowardsFuturePayments" => false,
      "isCalendarInherited" => false,
      "withdrawalFeeForTransfers" => false,
      "depositType" => %{
        "id" => 300,
        "code" => "depositAccountType.recurringDeposit",
        "value" => "Recurring Deposit"
      },
      "withHoldTax" => false
    }
    |> Map.merge(client)
    |> Map.merge(product)
    |> Map.merge(
      Map.take(
        FixedDepositAccounts.options(),
        ~w(preClosurePenalInterestOnTypeOptions periodFrequencyTypeOptions)
      )
    )
    |> Map.merge(
      if product_id,
        do: Map.delete(FixedDepositAccounts.product_choices(), "maturityInstructionOptions"),
        else: %{}
    )
    |> Map.put(
      "productOptions",
      Enum.map(DepositProducts.list(:recurring), &FixedDepositAccounts.product_option/1)
    )
    |> Map.put("chargeOptions", FixedDepositAccounts.charge_options(product_id))
  end

  # Fineract shows the type of a recurring deposit as that of a fixed one
  defp fixed_type,
    do: %{"id" => 200, "code" => "depositAccountType.fixedDeposit", "value" => "Fixed Deposit"}

  defp template_product(nil), do: {:ok, %{}}

  # a product that is not there ends in an unhandled error in Fineract's template
  defp template_product(id) do
    with {:ok, p} <- FixedDepositAccounts.unhandled(DepositProducts.get(:recurring, id)) do
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
         "isMandatoryDeposit" => p[:is_mandatory] == true,
         "allowWithdrawal" => p[:allow_withdrawal] == true,
         "adjustAdvanceTowardsFuturePayments" =>
           p[:adjust_advance_towards_future_payments] == true,
         "isCalendarInherited" => false,
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
         "depositType" => fixed_type(),
         "withHoldTax" => p.withhold_tax == true,
         "charges" => [],
         "accountChart" => FixedDepositAccounts.product_chart(DepositProducts.charts(p.id), p)
       }}
    end
  end

  # --- writes -------------------------------------------------------------------------------------------

  @doc "`POST /recurringdepositaccounts`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /recurringdepositaccounts/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /recurringdepositaccounts/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  @doc "`POST /recurringdepositaccounts/:id?command=...`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      command = conn.query_params["command"]
      key = command && command |> String.trim() |> String.downcase()

      if Map.has_key?(@commands, key) do
        Write.execute(conn, @resource, Map.fetch!(@commands, key), id: id)
      else
        Errors.render(conn, %UnrecognizedQueryParameter{
          name: "command",
          value: command,
          allowed: @command_names
        })
      end
    end)
  end
end
