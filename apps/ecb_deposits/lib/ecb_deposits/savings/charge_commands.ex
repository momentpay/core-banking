defmodule ECBDeposits.Savings.ChargeCommands do
  @moduledoc """
  The commands on the charges of a savings account (adding, changing, deleting, paying, waiving and inactivating a
  charge), after Fineract's `SavingsAccountWritePlatformServiceJpaRepositoryImpl` (`addSavingsAccountCharge`,
  `updateSavingsAccountCharge`, `deleteSavingsAccountCharge`, `waiveCharge`, `payCharge`, `inactivateCharge`),
  `SavingsAccount` and `SavingsAccountChargeDataValidator`. Charges that give free withdrawals or belong to a payment
  type are refused as not supported yet. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.{Charges, Postings, Transitions}
  alias ECBOrg.{Holidays, WorkingDays}
  alias ECBPlatform.{BusinessDate, Configuration, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformApiDataValidation}
  alias ECBPlatform.Params.DatePattern
  alias ECBPlatform.RecurrenceRule

  @add_supported ~w(chargeId amount dueDate dateFormat locale feeOnMonthDay monthDayFormat feeInterval)
  @pay_supported ~w(amount dueDate dateFormat locale)
  @active 300
  @approved 200
  @closed 600

  # --- adding ---------------------------------------------------------------------------------------

  @doc "Adds a charge to the account."
  @spec add!(struct, integer, Params.t()) :: Result.t()
  def add!(user, account_id, %Params{} = p) do
    Params.check_supported!(p, @add_supported)
    charge_id = Params.long(p, "chargeId")
    amount = Params.decimal_with_locale(p, "amount")
    due_date = Params.date(p, "dueDate")
    month_day = month_day(p)

    v =
      Validation.new("savingsaccountcharge")
      |> Validation.param("chargeId", charge_id)
      |> Validation.not_null()
      |> Validation.greater_than_zero()
      |> Validation.param("amount", amount)
      |> Validation.not_null()
      |> Validation.positive_amount()

    v =
      if Params.exists?(p, "dueDate"),
        do: v |> Validation.param("dueDate", due_date) |> Validation.not_null(),
        else: v

    v =
      if Params.exists?(p, "feeOnMonthDay"),
        do: v |> Validation.param("feeOnMonthDay", month_day) |> Validation.not_null(),
        else: v

    Validation.raise_if_errors!(v)

    account = Transitions.account!(account_id)
    definition = Charges.definition(charge_id) || raise(ECBCatalog.Charges.not_found(charge_id))
    refuse_unsupported!(definition)

    errors = date_not_allowed_for_time(definition, p)

    attrs = %{
      amount: amount,
      due_date: due_date,
      month_day: month_day,
      fee_interval: Params.integer_with_locale(p, "feeInterval")
    }

    charge = Charges.build(definition, attrs, account.currency_digits)
    errors = errors ++ rounded_to_zero(charge) ++ due_date_not_allowed(account, charge, p)
    if errors != [], do: raise(%PlatformApiDataValidation{errors: errors})

    check_addable!(account, charge, p)
    charge = due_for(account, charge)

    id = Charges.create!(user, account_id, charge)

    Result.new(
      resource_id: id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: account_id
    )
  end

  # a charge that gives free withdrawals or belongs to a payment type is not built yet
  defp refuse_unsupported!(definition) do
    asked =
      [
        {"isFreeWithdrawal", definition.free_withdrawal == true},
        {"isPaymentType", definition.payment_type == true}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if asked != [] do
      raise DomainRuleViolation,
        code: "error.msg.savingsaccount.feature.not.supported.yet",
        message:
          "These savings charge settings are not supported yet by E-CoreBank: " <>
            Enum.join(asked, ", "),
        args: asked
    end
  end

  # a withdrawal fee or a no-activity fee has no due date to be given
  defp date_not_allowed_for_time(definition, p) do
    due = Params.string(p, "dueDate")

    if definition.time in [5, 16] and due != nil do
      code =
        if definition.time == 5,
          do: "chargeTimeType.withdrawalFee",
          else: "chargeTimeType.savingsNoActivityFee"

      [error("charge.due.date.is.invalid.for." <> code, "dueDate", due)]
    else
      []
    end
  end

  defp rounded_to_zero(%{calculation: 1, amount: amount}) do
    if Decimal.eq?(amount, 0),
      do: [
        ECBPlatform.Errors.parameter_error(
          "error.msg.savings.charge.amount.rounded.to.zero",
          "This charge cannot be added because the calculated amount becomes zero after rounding.",
          "amount",
          []
        )
      ],
      else: []
  end

  defp rounded_to_zero(_charge), do: []

  # a due date is not allowed on a holiday or a day off, unless the configuration allows it
  defp due_date_not_allowed(account, %{due_date: date}, p) when not is_nil(date) do
    text = Params.string(p, "dueDate")

    holiday =
      if on_holiday?(account.client_office_id, date),
        do: [error("charge.due.date.is.on.holiday", "dueDate", text)],
        else: []

    day_off =
      if day_off?(date),
        do: [error("charge.due.date.is.a.nonworking.day", "dueDate", text)],
        else: []

    holiday ++ day_off
  end

  defp due_date_not_allowed(_account, _charge, _p), do: []

  @doc false
  def on_holiday?(office_id, date) do
    not Configuration.enabled?("allow-transactions-on-holiday") and office_id != nil and
      Enum.any?(
        Holidays.active_from(office_id, date),
        &(Date.compare(&1.from_date, date) != :gt and Date.compare(&1.to_date, date) != :lt)
      )
  end

  @doc false
  def day_off?(date) do
    not Configuration.enabled?("allow-transactions-on-non-working-day") and
      case WorkingDays.get() do
        %{recurrence: rule} when is_binary(rule) -> not RecurrenceRule.working_day?(rule, date)
        _ -> false
      end
  end

  # `SavingsAccount.addCharge`
  defp check_addable!(account, charge, p) do
    if account.status_enum == @closed, do: general!("transaction.invalid.account.is.closed")

    if Charges.specified_due_date?(charge),
      do: check_due_date!(account, charge, Params.date_format(p))

    if Charges.activation?(charge) and account.status_enum not in [100, @approved],
      do: general!("not.valid.account.status.cannot.add.activation.time.charge")

    if Charges.annual?(charge) and Enum.any?(Charges.list(account.id), &Charges.annual?/1),
      do: general!("multiple.annual.fee.per.account.not.supported")
  end

  # a charge on a date is not due before the account was activated or applied for
  defp check_due_date!(account, charge, pattern) do
    cond do
      account.activatedon_date && Date.compare(charge.due_date, account.activatedon_date) == :lt ->
        param_error!(
          "dueDate",
          DatePattern.format(account.activatedon_date, pattern),
          "before.activationDate"
        )

      Date.compare(charge.due_date, account.submittedon_date) == :lt ->
        param_error!(
          "dueDate",
          DatePattern.format(account.submittedon_date, pattern),
          "before.submittedOnDate"
        )

      true ->
        :ok
    end
  end

  # recurring fees fall due next after the day the account was activated (or approved)
  defp due_for(account, charge) do
    cond do
      not Charges.recurring?(charge) ->
        charge

      account.status_enum == @active ->
        %{charge | due_date: Charges.next_due_from(charge, account.activatedon_date)}

      account.status_enum == @approved ->
        %{charge | due_date: Charges.next_due_from(charge, account.approvedon_date)}

      true ->
        charge
    end
  end

  # --- changing -------------------------------------------------------------------------------------

  @doc "Changes the amount, the due date or the day a fee falls on of a charge."
  @spec update!(struct, integer, integer, Params.t()) :: Result.t()
  def update!(user, account_id, charge_id, %Params{} = p) do
    Params.check_supported!(p, @add_supported)
    amount = Params.decimal_with_locale(p, "amount")
    due_date = Params.date(p, "dueDate")
    month_day = month_day(p)

    v =
      Validation.new("savingsaccountcharge")
      |> Validation.param("amount", amount)
      |> Validation.not_null()
      |> Validation.positive_amount()

    v =
      if Params.exists?(p, "dueDate"),
        do: v |> Validation.param("dueDate", due_date) |> Validation.not_null(),
        else: v

    v =
      if Params.exists?(p, "feeOnMonthDay"),
        do: v |> Validation.param("feeOnMonthDay", month_day) |> Validation.not_null(),
        else: v

    interval = Params.integer_with_locale(p, "feeInterval")

    v =
      if Params.exists?(p, "feeInterval"),
        do:
          v
          |> Validation.param("feeInterval", interval)
          |> Validation.not_null()
          |> Validation.in_range(1, 12),
        else: v

    Validation.raise_if_errors!(v)

    account = Transitions.account!(account_id)
    charge = Charges.get(account_id, charge_id) || raise Charges.not_found(charge_id)
    {charge, changes} = apply_changes(charge, p, amount, due_date, month_day)

    if charge.due_date != nil do
      errors = due_date_not_allowed(account, charge, p)
      if errors != [], do: raise(%PlatformApiDataValidation{errors: [hd(errors)]})
    end

    Charges.save!(user, charge)

    Result.new(
      resource_id: charge.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: account_id,
      changes: if(changes == %{}, do: nil, else: changes)
    )
  end

  # `SavingsAccountCharge.update(command)`: what changed, in the order Fineract reports it
  defp apply_changes(c, p, amount, due_date, month_day) do
    {c, changes} = change_due_date(c, p, due_date, %{})
    {c, changes} = change_month_day(c, p, month_day, changes)
    change_amount(c, p, amount, changes)
  end

  defp change_due_date(c, p, due_date, changes) do
    if Params.exists?(p, "dueDate") and due_date != nil and due_date != c.due_date do
      c = %{c | due_date: due_date}
      c = if Charges.weekly?(c), do: %{c | fee_on_day: Date.day_of_week(due_date)}, else: c

      {c,
       Map.merge(changes, %{
         "dueDate" => Params.string(p, "dueDate"),
         "dateFormat" => Params.string(p, "dateFormat"),
         "locale" => Params.string(p, "locale")
       })}
    else
      {c, changes}
    end
  end

  defp change_month_day(c, p, month_day, changes) do
    case month_day do
      {month, day} when c.fee_on_day != nil ->
        changed? = c.fee_on_day != day or c.fee_on_month != month

        if changed?,
          do:
            {%{c | fee_on_day: day, fee_on_month: month},
             Map.merge(changes, %{
               "feeOnMonthDay" => Params.string(p, "feeOnMonthDay"),
               "locale" => Params.string(p, "locale")
             })},
          else: {c, changes}

      _ ->
        {c, changes}
    end
  end

  # the amount is compared with the amount stored, which for a charge worked out as a percentage is nothing
  defp change_amount(c, p, amount, changes) do
    if amount != nil and not Decimal.eq?(amount, c.amount || 0) do
      c =
        if Charges.flat?(c),
          do: %{c | amount: amount},
          else: %{c | percentage: amount, applied_to: Decimal.new(0), amount: Decimal.new(0)}

      c = %{c | outstanding: outstanding(c)}
      {c, Map.merge(changes, %{"amount" => amount, "locale" => Params.string(p, "locale")})}
    else
      {c, changes}
    end
  end

  defp outstanding(c) do
    (c.amount || Decimal.new(0)) |> Decimal.sub(c.paid || 0) |> Decimal.sub(c.waived_amount || 0)
  end

  # --- deleting -------------------------------------------------------------------------------------

  @doc "Deletes a charge of an account that is still only an application."
  @spec delete!(struct, integer, integer) :: Result.t()
  def delete!(_user, account_id, charge_id) do
    account = Transitions.account!(account_id)
    charge = Charges.get(account_id, charge_id) || raise Charges.not_found(charge_id)

    cond do
      account.status_enum == @closed ->
        general!("delete.transaction.invalid.account.is.closed")

      account.status_enum in [@active, @approved] ->
        general!("delete.transaction.invalid.account.is.active")

      true ->
        :ok
    end

    TenantRepo.delete_all(from(x in "m_savings_account_charge", where: x.id == ^charge.id))

    Result.new(
      resource_id: charge.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: account_id
    )
  end

  # --- waiving --------------------------------------------------------------------------------------

  @doc "Waives what is outstanding of a charge."
  @spec waive!(struct, integer, integer) :: Result.t()
  def waive!(user, account_id, charge_id) do
    charge = Charges.get(account_id, charge_id) || raise Charges.not_found(charge_id)
    account = Transitions.account!(account_id)

    if account.status_enum == @closed, do: general!("transaction.invalid.account.is.closed")
    if account.status_enum != @active, do: general!("transaction.invalid.account.is.not.active")
    if not charge.is_active, do: general!("charge.is.not.active")

    if Charges.withdrawal_fee?(charge),
      do: general!("transaction.invalid.waiver.of.withdrawal.fee.not.supported")

    already_settled!(charge)

    Postings.waive_charge!(user, account, charge)

    Result.new(
      resource_id: charge.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: account_id
    )
  end

  defp already_settled!(%{waived: true}),
    do: general!("transaction.invalid.account.charge.is.already.waived")

  defp already_settled!(%{is_paid: true}),
    do: general!("transaction.invalid.account.charge.is.paid")

  defp already_settled!(_charge), do: :ok

  # --- paying ---------------------------------------------------------------------------------------

  @doc "Pays all or some of what is outstanding of a charge from the account."
  @spec pay!(struct, integer, integer, Params.t()) :: Result.t()
  def pay!(user, account_id, charge_id, %Params{} = p) do
    Params.check_supported!(p, @pay_supported)
    amount = Params.decimal_with_locale(p, "amount")
    date = Params.date(p, "dueDate")

    Validation.new("savingsaccountcharge")
    |> Validation.param("amount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.param("dueDate", date)
    |> Validation.not_null()
    |> Validation.raise_if_errors!()

    charge = Charges.get(account_id, charge_id) || raise Charges.not_found(charge_id)
    account = Transitions.account!(account_id)
    text = Params.string(p, "dueDate")

    if on_holiday?(account.client_office_id, date),
      do: param_error!("dueDate", text, "transaction.not.allowed.transaction.date.is.on.holiday")

    if day_off?(date),
      do:
        param_error!(
          "dueDate",
          text,
          "transaction.not.allowed.transaction.date.is.a.nonworking.day"
        )

    tx_id = pay_checked!(user, account, charge, date, amount, Params.date_format(p))

    Result.new(
      resource_id: charge.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: account_id,
      transaction_id: Integer.to_string(tx_id)
    )
  end

  @doc """
  Pays a charge on a date as `payCharge` of the write service does: the account must be able to pay it (an account
  that may not be overdrawn needs the balance of its last transaction up to the date), then the rules of
  `SavingsAccount.payCharge`.
  """
  @spec pay_checked!(struct, map, map, Date.t(), Decimal.t(), String.t() | nil) :: integer
  def pay_checked!(user, account, charge, date, amount, pattern) do
    enough_balance!(account, date, amount)
    check_payable!(account, charge, date, amount, pattern)
    Postings.pay_charge!(user, Transitions.account!(account.id), charge, date, amount)
  end

  defp enough_balance!(account, date, amount) do
    unless account.allow_overdraft == true do
      latest =
        TenantRepo.one(
          from(t in "m_savings_account_transaction",
            where:
              t.savings_account_id == ^account.id and not t.is_reversed and
                t.transaction_date <= ^date,
            order_by: [desc: t.transaction_date, desc: t.id],
            limit: 1,
            select: t.running_balance_derived
          )
        )

      {balance, shown} =
        case latest do
          nil -> {Decimal.new(0), Decimal.new(0)}
          running -> {running, ECBDeposits.Savings.fetch!(account.id).account_balance_derived}
        end

      if Decimal.lt?(Decimal.sub(balance, amount), 0) do
        raise DomainRuleViolation,
          code: "error.msg.savingsaccount.transaction.insufficient.account.balance",
          message: "Insufficient account balance.",
          args: ["transactionAmount", shown, nil, amount]
      end
    end
  end

  # `SavingsAccount.payCharge`
  defp check_payable!(account, charge, date, amount, pattern) do
    if account.status_enum == @closed, do: general!("transaction.invalid.account.is.closed")
    if account.status_enum != @active, do: general!("transaction.invalid.account.is.not.active")
    if not charge.is_active, do: general!("charge.is.not.active")

    if Date.compare(date, account.activatedon_date) == :lt,
      do:
        param_error!(
          "dueDate",
          DatePattern.format(account.activatedon_date, pattern),
          "transaction.before.activationDate"
        )

    if Date.compare(date, BusinessDate.current()) == :gt,
      do: param_error!("dueDate", DatePattern.format(date, pattern), "transaction.is.futureDate")

    if Charges.activation?(charge),
      do: general!("transaction.not.valid.cannot.pay.activation.time.charge.is.automated")

    if Charges.annual?(charge), do: check_annual_fee!(account, charge, date, pattern)

    already_settled!(charge)

    if Decimal.lt?(charge.outstanding, amount),
      do: general!("transaction.invalid.charge.amount.paid.in.access")
  end

  defp check_annual_fee!(account, charge, date, pattern) do
    if charge.due_date == nil, do: general!("no.annualfee.settings")
    if Date.compare(date, charge.due_date) == :lt, do: general!("transaction.before.dueDate")

    latest =
      TenantRepo.one(
        from(t in "m_savings_account_transaction",
          where:
            t.savings_account_id == ^account.id and t.transaction_type_enum == 5 and
              not t.is_reversed and
              not t.is_reversal,
          select: max(t.transaction_date)
        )
      )

    if latest != nil and Date.compare(latest, date) == :eq,
      do: param_error!("dueDate", DatePattern.format(date, pattern), "transaction.exists.on.date")
  end

  # --- inactivating ---------------------------------------------------------------------------------

  @doc "Makes a recurring charge stop falling due."
  @spec inactivate!(struct, integer, integer) :: Result.t()
  def inactivate!(user, account_id, charge_id) do
    charge = Charges.get(account_id, charge_id) || raise Charges.not_found(charge_id)
    account = Transitions.account!(account_id)
    today = BusinessDate.current()

    if not Charges.recurring?(charge),
      do:
        general_with!(
          "savingsaccountcharge",
          "charge.inactivation.allowed.only.for.recurring.charges",
          [charge.id]
        )

    next = Charges.next_due_from(charge, today)

    cond do
      Date.compare(charge.due_date, next) == :lt ->
        general_with!(
          "savingsaccountcharge",
          "inactivation.of.charge.not.allowed.when.charge.is.due",
          []
        )

      Date.compare(charge.due_date, next) == :gt and Decimal.gt?(charge.paid || Decimal.new(0), 0) ->
        raise DomainRuleViolation,
          code: "error.msg.savingsaccount.feature.not.supported.yet",
          message:
            "Inactivating a charge that is paid in advance is not supported yet by E-CoreBank",
          args: ["inactivate"]

      true ->
        :ok
    end

    Charges.save!(user, %{
      charge
      | is_active: false,
        inactivated_on_date: today,
        outstanding: Decimal.new(0),
        is_paid: true
    })

    Result.new(
      resource_id: charge.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: account_id
    )
  end

  # --- the jobs ---------------------------------------------------------------------------------------

  @doc "The job that pays what is due: pays the outstanding of the charge on the business date while it fell due before."
  @spec pay_due!(struct, integer, integer) :: :ok
  def pay_due!(user, charge_id, account_id) do
    today = BusinessDate.current()
    pay_due_loop!(user, account_id, charge_id, today)
  end

  defp pay_due_loop!(user, account_id, charge_id, today) do
    charge = Charges.get(account_id, charge_id)

    if (charge && not charge.is_paid && charge.due_date != nil) and
         Date.compare(charge.due_date, today) == :lt do
      account = Transitions.account!(account_id)
      pay_checked!(user, account, charge, today, charge.outstanding, nil)
      pay_due_loop!(user, account_id, charge_id, today)
    else
      :ok
    end
  end

  @doc "The job that applies annual fees: pays the fee on each of the days it fell due until today."
  @spec apply_annual_fee!(struct, integer, integer) :: :ok
  def apply_annual_fee!(user, charge_id, account_id) do
    today = BusinessDate.current()
    annual_loop!(user, account_id, charge_id, today)
  end

  defp annual_loop!(user, account_id, charge_id, today) do
    charge = Charges.get(account_id, charge_id)

    if (charge && charge.due_date != nil) and Date.compare(charge.due_date, today) == :lt do
      account = Transitions.account!(account_id)
      pay_checked!(user, account, charge, charge.due_date, charge.amount, nil)
      annual_loop!(user, account_id, charge_id, today)
    else
      :ok
    end
  end

  # --- errors ---------------------------------------------------------------------------------------

  defp general!(code), do: general_with!("savingsaccount", code, [])

  # the value of the first argument, when the error names one (the charge it is about), is in its arguments
  defp general_with!(resource, code, args) do
    resource
    |> Validation.new()
    |> Validation.param(nil, List.first(args))
    |> Validation.fail_without_parameter(code)
    |> Validation.raise_if_errors!()
  end

  defp param_error!(parameter, text, code) do
    "savingsaccount"
    |> Validation.new()
    |> Validation.param(parameter, text)
    |> Validation.fail_without_parameter(code)
    |> Validation.raise_if_errors!()
  end

  defp error(code, parameter, text) do
    "savingsaccount"
    |> Validation.new()
    |> Validation.param(parameter, text)
    |> Validation.fail_without_parameter(code)
    |> Map.fetch!(:errors)
    |> hd()
  end

  # the day and month a fee falls on, `{month, day}`, as the request's `monthDayFormat` writes it
  defp month_day(p) do
    case Params.string(p, "feeOnMonthDay") do
      nil ->
        nil

      text ->
        format = Params.string(p, "monthDayFormat") || raise ECBPlatform.Errors.ServerError
        with_year = if String.contains?(format, ["y", "u"]), do: format, else: format <> " yyyy"
        shown = if with_year == format, do: text, else: text <> " 2000"

        case DatePattern.parse(shown, with_year) do
          {:ok, date} ->
            {date.month, date.day}

          :error ->
            raise PlatformApiDataValidation,
              errors: [
                %{
                  code: "validation.msg.invalid.month.day",
                  developer_message:
                    "The parameter `feeOnMonthDay` is invalid based on the monthDayFormat: `#{format}` and locale: `#{Params.locale(p)}` provided:",
                  default_message: "feeOnMonthDay",
                  parameter: text,
                  args: [format]
                }
              ]
        end
    end
  end
end
