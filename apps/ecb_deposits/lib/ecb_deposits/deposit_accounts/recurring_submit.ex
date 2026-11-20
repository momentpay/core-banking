defmodule ECBDeposits.DepositAccounts.RecurringSubmit do
  @moduledoc """
  Applying for a recurring deposit account, changing the application and deleting it, after Fineract's
  `DepositApplicationProcessWritePlatformServiceJpaRepositoryImpl`, `RecurringDepositAccount` and
  `DepositAccountRecurringDetail`. The account is made like a fixed deposit account (it copies the term, the penalty
  and the interest rate chart of its product) and also gets the details of its installments, a calendar that says
  when they fall due and a schedule of them. The deposit amount is what all the installments come to; the rate
  is that of the chart for it and the term, and the maturity amount what the installments earn if they are paid on
  their days. Must run inside a tenant scope.

  Refused as not supported yet: following the meeting of a group (`isCalendarInherited`), accounts of a group, a term
  that is open-ended, withholding tax, and charts with incentives.
  """
  import Ecto.Query

  alias ECBDeposits.{DepositAccounts, DepositEnums, DepositProducts}
  alias ECBDeposits.DepositAccounts.{Maturity, Recurring, Submit}
  alias ECBDeposits.Savings.{ApplicationCharges, Charges}
  alias ECBDeposits.Savings.Submit, as: SavingsSubmit
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Integrity, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DataIntegrity, DomainRuleViolation}

  @resource "recurringdepositaccount"
  @pending 100

  @recurring_parameters ~w(mandatoryRecommendedDepositAmount isMandatoryDeposit allowWithdrawal
                           adjustAdvanceTowardsFuturePayments recurringFrequencyType recurringFrequency
                           isCalendarInherited)

  @doc "The parameters an application or a change may carry."
  @spec supported() :: [String.t()]
  def supported,
    do:
      (Submit.supported() -- ~w(linkAccountId transferInterestToSavings)) ++ @recurring_parameters

  # --- applying -----------------------------------------------------------------------------------

  @doc "Submits the application `p` describes."
  @spec create!(struct, Params.t()) :: Result.t()
  def create!(user, %Params{} = p) do
    Params.check_supported!(p, supported())
    on = Params.date(p, "submittedOnDate")
    validate!(p, :create)
    ApplicationCharges.validate!(p)
    refuse_group!(p)

    product = product!(Json.long(p, "productId"))
    client = SavingsSubmit.client!(p)
    staff = SavingsSubmit.staff!(p)
    Submit.refuse_withholding!(p, product)
    charges = ApplicationCharges.build!(p, product)
    chart = Submit.chart_for(product, on)
    Submit.refuse_incentives!(chart)

    row = on |> account_row(user, p, product, client, staff)
    term = Submit.term_row(p, product)
    domain_rules!(@resource, term, start_date(term, on), on)
    Submit.new_application_state!(on, client, @resource)
    refuse_open_ended!(term)

    id = SavingsSubmit.insert!(row)
    supplied? = SavingsSubmit.blank_to_nil(Params.string(p, "accountNo")) != nil
    refuse_account_no!(supplied?)

    TenantRepo.insert_all("m_deposit_account_term_and_preclosure", [
      Map.put(term, :savings_account_id, id)
    ])

    insert_detail!(id, p, product)
    if chart, do: Submit.copy_chart!(id, chart)
    Enum.each(charges, &Charges.create!(user, id, &1))
    unless supplied?, do: SavingsSubmit.generate_account_no!(id, product, client)
    refuse_inherited!(p, client)

    Recurring.create_calendar!(
      user,
      id,
      start_date(term, on),
      Params.integer(p, "recurringFrequencyType"),
      Params.integer(p, "recurringFrequency")
    )

    regenerate!(user, id)

    Result.new(office_id: client.office_id, client_id: client.id, savings_id: id, resource_id: id)
  end

  # an application names a product of its own kind in the words of the recurring deposit
  defp product!(id) do
    case DepositProducts.get(:recurring, id) do
      {:ok, product} -> product
      {:error, _} -> raise DepositProducts.not_found(:recurring, id)
    end
  end

  defp account_row(on, user, p, product, client, staff) do
    row = SavingsSubmit.new_row(user, p, product, client, staff, on)
    %{row | deposit_type_enum: DepositEnums.recurring(), withdrawal_fee_for_transfer: false}
  end

  defp start_date(term, on), do: term.expected_firstdepositon_date || on

  # a term that never ends has no maturity date and its schedule is made a few installments at a time
  defp refuse_open_ended!(%{deposit_period: nil}),
    do: unsupported!("A recurring deposit without a term is", ["depositPeriod"])

  defp refuse_open_ended!(_term), do: :ok

  defp refuse_group!(p) do
    if Json.long(p, "groupId") != nil and Json.long(p, "clientId") == nil,
      do: unsupported!("Recurring deposit accounts of groups are", ["groupId"])
  end

  defp unsupported!(what, args), do: Submit.unsupported!(what, args)

  # the details of the installments: what the application says, else what the product says
  defp insert_detail!(id, p, product) do
    TenantRepo.insert_all("m_deposit_account_recurring_detail", [
      %{
        savings_account_id: id,
        mandatory_recommended_deposit_amount:
          Params.decimal_with_locale(p, "mandatoryRecommendedDepositAmount"),
        is_mandatory: flag(p, "isMandatoryDeposit", product[:is_mandatory]),
        allow_withdrawal: flag(p, "allowWithdrawal", product[:allow_withdrawal]),
        adjust_advance_towards_future_payments:
          flag(
            p,
            "adjustAdvanceTowardsFuturePayments",
            product[:adjust_advance_towards_future_payments]
          ),
        is_calendar_inherited: false
      }
    ])
  end

  defp flag(p, key, fallback) do
    case Params.boolean(p, key) do
      nil -> fallback == true
      value -> value
    end
  end

  # --- the calendar -------------------------------------------------------------------------------------

  # With an account number of its own Fineract has not saved the account when it saves the calendar, and fails on a
  # calendar that has no account. It has used an id for the account by then, but nothing else.
  defp refuse_account_no!(true),
    do:
      raise(DataIntegrity,
        code: "error.msg.savingsaccount.unknown.data.integrity.issue",
        message: "Unknown data integrity issue with savings account.",
        parameter: nil,
        args: []
      )

  defp refuse_account_no!(false), do: :ok

  # Without a group to follow the account has no meeting to take its days from.
  defp refuse_inherited!(p, client) do
    if Params.boolean(p, "isCalendarInherited") == true do
      raise DomainRuleViolation,
        code:
          "error.msg.recurring.deposit.account.cannot.create.not.belongs.to.any.groups.to.follow.meeting.frequency",
        message:
          "Client does not belong to group/center. Cannot follow group/center meeting frequency.",
        args: [client && client.id]
    end
  end

  # --- the schedule and the maturity -----------------------------------------------------------------------

  @doc """
  Works the schedule, the deposit amount, the rate and the maturity of account `id` out again from what it says now,
  and stores them. Unless `check?: false`, the rate must be possible: there must be a chart slab for the day and the
  rate of the chart (or the account's own) must not be zero.
  """
  @spec regenerate!(struct, integer, keyword) :: :ok
  def regenerate!(user, id, opts \\ []) do
    account = DepositAccounts.fetch!(:recurring, id)
    term = account.term
    detail = DepositAccounts.recurring_detail(id)
    {type, every} = id |> Recurring.calendar() |> Map.fetch!(:recurrence) |> Recurring.parse()
    start = term.expected_first_deposit_on || account.activatedon_date || account.submittedon_date
    maturity = Maturity.date(start, term.deposit_period, term.deposit_period_frequency)
    installments = Recurring.installments(start, maturity, type, every, detail.amount)
    chart = DepositAccounts.chart(id)
    total = Recurring.total(installments)
    rate = rate(account, chart, total, start, maturity)
    if Keyword.get(opts, :check?, true), do: check_rate!(account, chart, rate)

    {deposit, amount} =
      Recurring.maturity_amounts(%{
        installments: installments,
        start: start,
        maturity: maturity,
        rate: rate,
        posting: account.interest_posting_period_enum,
        compounding: account.interest_compounding_period_enum,
        calculation: account.interest_calculation_type_enum,
        days_in_year: account.interest_calculation_days_in_year_type_enum,
        min_balance: account.min_balance_for_interest_calculation,
        decimals: account.currency_digits
      })

    Recurring.write_schedule!(user, id, installments)

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [nominal_annual_interest_rate: rate]
    )

    TenantRepo.update_all(
      from(t in "m_deposit_account_term_and_preclosure", where: t.savings_account_id == ^id),
      set: [deposit_amount: deposit, maturity_amount: amount, maturity_date: maturity]
    )

    :ok
  end

  defp rate(account, nil, _total, _start, _maturity), do: account.nominal_annual_interest_rate

  defp rate(_account, chart, total, start, maturity),
    do: Maturity.rate(chart.slabs, total, start, maturity)

  # Fineract's `validateApplicableInterestRate`
  defp check_rate!(account, chart, rate) do
    on = account.activatedon_date || account.submittedon_date

    @resource
    |> Validation.new()
    |> rate_problems(chart, rate, on)
    |> Validation.raise_if_errors!()
  end

  defp rate_problems(v, nil, rate, _on) do
    if rate == nil or Decimal.eq?(rate, 0),
      do:
        Validation.scoped(v, fn v ->
          v
          |> Validation.param("nominalAnnualInterestRate", rate)
          |> Validation.fail_without_parameter("interest.chart.or.nominal.interest.rate.required")
        end),
      else: v
  end

  defp rate_problems(v, chart, rate, on) do
    v = if in_chart?(chart, on), do: v, else: slab_missing(v)
    if Decimal.eq?(rate, 0), do: no_rate(v), else: v
  end

  defp in_chart?(chart, on) do
    last = chart.end_date || BusinessDate.current()
    Date.compare(on, chart.from_date) != :lt and Date.compare(on, last) != :gt
  end

  defp slab_missing(v),
    do:
      Validation.scoped(
        v,
        &Validation.fail_without_parameter(
          &1,
          "no.valid.interest.rate.slab.available.for.date.range"
        )
      )

  defp no_rate(v),
    do:
      Validation.scoped(
        v,
        &Validation.fail_without_parameter(
          &1,
          "no.applicable.interest.rate.is.found.based.on.amount.and.deposit.period"
        )
      )

  # --- the rules of the whole application ----------------------------------------------------------------

  @doc false
  def domain_rules!(resource, term, start, on) do
    resource
    |> Validation.new()
    |> Submit.terms_ordered(term)
    |> period_given(term)
    |> period_rules(term, start)
    |> first_deposit(term, on)
    |> Validation.raise_if_errors!()
  end

  defp period_given(v, %{max_deposit_term: nil}), do: v

  defp period_given(v, term) do
    Validation.scoped(v, fn v ->
      v |> Validation.param("depositPeriod", term.deposit_period) |> Validation.not_null()
    end)
  end

  defp period_rules(v, %{deposit_period: nil}, _start), do: v
  defp period_rules(v, term, start), do: Submit.deposit_period(v, term, start)

  defp first_deposit(v, %{expected_firstdepositon_date: nil}, _on), do: v

  defp first_deposit(v, term, on) do
    if Date.compare(term.expected_firstdepositon_date, on) == :lt,
      do:
        Validation.scoped(
          v,
          &Validation.fail_without_parameter(
            &1,
            "expected.first.deposit.date.must.be.after.account.submitted.or.activation.date"
          )
        ),
      else: v
  end

  # --- checking a request ---------------------------------------------------------------------------------

  defp validate!(p, mode) do
    @resource
    |> Validation.new()
    |> Submit.references(p, mode)
    |> Submit.field_officer(p)
    |> Submit.submitted_on(p, mode)
    |> Submit.text_fields(p)
    |> Submit.interest_settings(p)
    |> Submit.lockin(p)
    |> Submit.maturity_instruction(p)
    |> Submit.pre_closure(p, mode)
    |> Submit.recurring_term(p, mode)
    |> recurring_detail(p, mode)
    |> Submit.withholding(p)
    |> Validation.raise_if_errors!()
  end

  defp recurring_detail(v, p, :create) do
    amount = Params.decimal_with_locale(p, "mandatoryRecommendedDepositAmount")

    v
    |> Validation.scoped(
      &(&1
        |> Validation.param("mandatoryRecommendedDepositAmount", amount)
        |> Validation.not_null()
        |> Validation.positive_amount())
    )
    |> flags(p)
    |> calendar_given(p)
  end

  defp recurring_detail(v, p, :update) do
    v = flags(v, p)

    v =
      if Params.exists?(p, "mandatoryRecommendedDepositAmount"),
        do:
          Validation.scoped(
            v,
            &(&1
              |> Validation.param(
                "mandatoryRecommendedDepositAmount",
                Params.decimal_with_locale(p, "mandatoryRecommendedDepositAmount")
              )
              |> Validation.not_null()
              |> Validation.positive_amount())
          ),
        else: v

    v =
      if Params.exists?(p, "isCalendarInherited"),
        do:
          Validation.scoped(
            v,
            &(&1
              |> Validation.param("isCalendarInherited", Params.boolean(p, "isCalendarInherited"))
              |> Validation.not_null()
              |> Validation.true_or_false())
          ),
        else: v

    v
    |> optional_frequency_type(p)
    |> optional_frequency(p)
  end

  defp flags(v, p) do
    Enum.reduce(
      ~w(isMandatoryDeposit allowWithdrawal adjustAdvanceTowardsFuturePayments),
      v,
      fn key, v ->
        if Params.exists?(p, key),
          do:
            Validation.scoped(
              v,
              &(&1
                |> Validation.param(key, Params.boolean(p, key))
                |> Validation.ignore_if_null()
                |> Validation.true_or_false())
            ),
          else: v
      end
    )
  end

  # asked for as text first: blank is "cannot be blank", anything else is read as true or false
  defp calendar_given(v, p) do
    text = Params.string(p, "isCalendarInherited")

    if text == nil or String.trim(text) == "" do
      Validation.scoped(
        v,
        &(&1 |> Validation.param("isCalendarInherited", text) |> Validation.not_blank())
      )
    else
      inherited = Params.boolean(p, "isCalendarInherited")

      v =
        Validation.scoped(
          v,
          &(&1
            |> Validation.param("isCalendarInherited", inherited)
            |> Validation.not_null()
            |> Validation.true_or_false())
        )

      if inherited == true, do: v, else: required_frequency(v, p)
    end
  end

  defp required_frequency(v, p) do
    ids = DepositEnums.term_unit_ids()

    v
    |> Validation.scoped(
      &(&1
        |> Validation.param("recurringFrequencyType", Params.integer(p, "recurringFrequencyType"))
        |> Validation.not_blank()
        |> Validation.one_of(ids))
    )
    |> Validation.scoped(
      &(&1
        |> Validation.param("recurringFrequency", Params.integer(p, "recurringFrequency"))
        |> Validation.not_null()
        |> Validation.greater_than_zero())
    )
  end

  defp optional_frequency_type(v, p) do
    if Params.exists?(p, "recurringFrequencyType"),
      do:
        Validation.scoped(
          v,
          &(&1
            |> Validation.param(
              "recurringFrequencyType",
              Params.integer(p, "recurringFrequencyType")
            )
            |> Validation.not_blank()
            |> Validation.one_of(DepositEnums.term_unit_ids()))
        ),
      else: v
  end

  defp optional_frequency(v, p) do
    if Params.exists?(p, "recurringFrequency"),
      do:
        Validation.scoped(
          v,
          &(&1
            |> Validation.param("recurringFrequency", Params.integer(p, "recurringFrequency"))
            |> Validation.not_null()
            |> Validation.greater_than_zero())
        ),
      else: v
  end

  # --- changing an application -------------------------------------------------------------------

  @doc "Changes what an application that is awaiting approval says."
  @spec modify!(struct, integer, Params.t()) :: Result.t()
  def modify!(user, id, %Params{} = p) do
    Params.check_supported!(p, supported())
    validate!(p, :update)
    refuse_changes!(p)

    account = writable!(id)
    client = Clients.fetch!(account.client_id)
    if client.status_enum != Clients.status(:active), do: SavingsSubmit.not_active!(client.id)

    if account.status_enum != @pending do
      @resource
      |> Kernel.<>(".modify")
      |> Validation.new()
      |> Validation.fail_without_parameter("not.in.submittedandpendingapproval.state")
      |> Map.update!(:errors, fn [e | rest] -> [Map.put(e, :parameter, nil) | rest] end)
      |> Validation.raise_if_errors!()
    end

    {changes, set, term_set} = Submit.changes(p, account)
    check_references!(p, changes)

    row = Map.merge(account, Map.new(set))

    term =
      Map.merge(
        account.term,
        Map.new(term_set, fn {column, value} -> {Submit.term_field(column), value} end)
      )

    on = row.submittedon_date

    term_row =
      Submit.term_columns(term)
      |> Map.put(:expected_firstdepositon_date, term.expected_first_deposit_on)

    domain_rules!(@resource <> ".modify", term_row, start_date(term_row, on), on)
    Submit.new_application_state!(on, client, @resource)

    store!(user, id, set, term_set)
    store_detail!(id, p)
    store_calendar!(user, id, p)
    regenerate!(user, id)

    Result.new(
      resource_id: id,
      savings_id: id,
      office_id: client.office_id,
      client_id: client.id,
      changes: changes
    )
  end

  # what E-CoreBank will not take from a change that Fineract takes: a calendar of a group's meeting
  defp refuse_changes!(p) do
    if Params.boolean(p, "isCalendarInherited") == true,
      do: unsupported!("Following the meeting of a group is", ["isCalendarInherited"])

    if Json.long(p, "groupId") != nil,
      do: unsupported!("Recurring deposit accounts of groups are", ["groupId"])
  end

  # Fineract takes the product to be any savings product; a recurring deposit has to be on one of its own
  defp check_references!(p, changes) do
    if Map.has_key?(changes, "productId"), do: product!(Json.long(p, "productId"))

    if Map.has_key?(changes, "clientId") and Json.long(p, "clientId") != nil do
      client = Clients.fetch!(Json.long(p, "clientId"))
      if client.status_enum != Clients.status(:active), do: SavingsSubmit.not_active!(client.id)
    end

    if Map.has_key?(changes, "fieldOfficerId") and Json.long(p, "fieldOfficerId") != nil,
      do: ECBOrg.Staff.fetch!(Json.long(p, "fieldOfficerId"))

    :ok
  end

  defp store!(user, id, set, term_set) do
    set = Keyword.merge(set, last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now())

    Integrity.translate(
      fn ->
        TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id), set: set)

        if term_set != [],
          do:
            TenantRepo.update_all(
              from(t in "m_deposit_account_term_and_preclosure",
                where: t.savings_account_id == ^id
              ),
              set: term_set
            )
      end,
      %{},
      {"error.msg.savingsaccount.unknown.data.integrity.issue",
       "Unknown data integrity issue with savings account."}
    )
  end

  # the amount and the flags of the installments, which Fineract does not list among a change's changes
  defp store_detail!(id, p) do
    set =
      for {key, column, reader} <- [
            {"mandatoryRecommendedDepositAmount", :mandatory_recommended_deposit_amount,
             &Params.decimal_with_locale/2},
            {"isMandatoryDeposit", :is_mandatory, &Params.boolean/2},
            {"allowWithdrawal", :allow_withdrawal, &Params.boolean/2},
            {"adjustAdvanceTowardsFuturePayments", :adjust_advance_towards_future_payments,
             &Params.boolean/2}
          ],
          Params.exists?(p, key),
          (value = reader.(p, key)) != nil,
          do: {column, value}

    if set != [],
      do:
        TenantRepo.update_all(
          from(d in "m_deposit_account_recurring_detail", where: d.savings_account_id == ^id),
          set: set
        )
  end

  # the calendar follows the account's first day of deposit and the frequency asked for; where one of the two is not
  # asked for the calendar keeps its own
  defp store_calendar!(user, id, p) do
    account = DepositAccounts.fetch!(:recurring, id)
    term = account.term
    start = term.expected_first_deposit_on || account.submittedon_date

    {type, every} =
      case Recurring.calendar(id) do
        nil -> {2, 1}
        %{recurrence: recurrence} -> Recurring.parse(recurrence)
      end

    type =
      if Params.exists?(p, "recurringFrequencyType"),
        do: Params.integer(p, "recurringFrequencyType"),
        else: type

    every =
      if Params.exists?(p, "recurringFrequency"),
        do: Params.integer(p, "recurringFrequency"),
        else: every

    Recurring.update_calendar!(user, id, start, type, every)
  end

  @doc false
  def writable!(id) do
    case DepositAccounts.get(:recurring, id) do
      nil -> raise ECBDeposits.Savings.not_found(id)
      account -> account
    end
  end

  # --- deleting ---------------------------------------------------------------------------------------

  @doc "Deletes an application that is awaiting approval."
  @spec delete!(struct, integer) :: Result.t()
  def delete!(_user, id) do
    account = writable!(id)
    client = Clients.fetch!(account.client_id)
    if client.status_enum != Clients.status(:active), do: SavingsSubmit.not_active!(client.id)

    if account.status_enum != @pending do
      (@resource <> ".delete")
      |> Validation.new()
      |> Validation.param("activatedOnDate", nil)
      |> Validation.fail_without_parameter("not.in.submittedandpendingapproval.state")
      |> Validation.raise_if_errors!()
    end

    TenantRepo.delete_all(from(n in "m_note", where: n.savings_account_id == ^id))

    TenantRepo.delete_all(
      from(h in "m_savings_officer_assignment_history", where: h.account_id == ^id)
    )

    TenantRepo.delete_all(
      from(s in "m_mandatory_savings_schedule", where: s.savings_account_id == ^id)
    )

    TenantRepo.delete_all(
      from(d in "m_deposit_account_recurring_detail", where: d.savings_account_id == ^id)
    )

    Recurring.delete_calendar!(id)
    Submit.delete_chart!(id)

    TenantRepo.delete_all(
      from(t in "m_deposit_account_term_and_preclosure", where: t.savings_account_id == ^id)
    )

    TenantRepo.delete_all(from(a in "m_savings_account", where: a.id == ^id))
    Result.new(resource_id: id, savings_id: id, office_id: client.office_id, client_id: client.id)
  end
end
