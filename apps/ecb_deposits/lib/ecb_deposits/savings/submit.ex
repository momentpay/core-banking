defmodule ECBDeposits.Savings.Submit do
  @moduledoc """
  Applying for a savings account, changing the application and withdrawing it (deleting), after Fineract's
  `SavingsApplicationProcessWritePlatformServiceJpaRepositoryImpl`, `SavingsAccountAssembler` and
  `SavingsAccountDataValidator`.

  The account copies the interest, overdraft and balance rules of its product, any of which the application may
  override. Applications with a withholding tax, a lien, a group or data tables are refused as not
  supported yet.
  """
  import Ecto.Query

  alias ECBDeposits.{Savings, SavingsEnums, SavingsProducts}
  alias ECBDeposits.Savings.{ApplicationCharges, Charges}
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Integrity, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, InvalidNumber}

  @pending 100

  @supported ~w(locale dateFormat monthDayFormat staffId isGSIM isParentAccount accountNo externalId clientId groupId
                productId fieldOfficerId submittedOnDate nominalAnnualInterestRate interestCompoundingPeriodType
                interestPostingPeriodType interestCalculationType interestCalculationDaysInYearType
                minRequiredOpeningBalance lockinPeriodFrequency lockinPeriodFrequencyType withdrawalFeeForTransfers
                feeAmount feeOnMonthDay charges allowOverdraft overdraftLimit minRequiredBalance
                enforceMinRequiredBalance lienAllowed maxAllowedLienLimit nominalAnnualInterestRateOverdraft
                minOverdraftForInterestCalculation withHoldTax datatables applicationId lastApplication)

  # --- applying -----------------------------------------------------------------------------------

  @doc "Submits the application `p` describes."
  @spec create!(struct, Params.t()) :: Result.t()
  def create!(user, %Params{} = p) do
    Params.check_supported!(p, @supported)
    on = Params.date(p, "submittedOnDate")
    validate!(p, :create)
    ApplicationCharges.validate!(p)
    refuse_beyond_core!(p)

    product = SavingsProducts.fetch!(Json.long(p, "productId"))
    client = client!(p)
    staff = staff!(p)
    row = new_row(user, p, product, client, staff, on)
    validate_application!(row, client, product)
    charges = ApplicationCharges.build!(p, product)

    supplied? = blank_to_nil(Params.string(p, "accountNo")) != nil
    id = insert!(row)
    Enum.each(charges, &Charges.create!(user, id, &1))
    unless supplied?, do: generate_account_no!(id, product, client)

    # without an account number of its own Fineract has not saved the account yet when it answers, so it
    # does not know its id
    ids = if supplied?, do: [], else: [resource_id: id, savings_id: id]

    Result.new([office_id: client.office_id, client_id: client.id, gsim_id: 0] ++ ids)
  end

  defp validate!(p, mode) do
    Validation.new("savingsaccount")
    |> validate_references(p, mode)
    |> optional_positive(p, "fieldOfficerId")
    |> then(
      &if(mode == :create or Params.exists?(p, "submittedOnDate"),
        do:
          &1
          |> Validation.param("submittedOnDate", Params.date(p, "submittedOnDate"))
          |> Validation.not_null(),
        else: &1
      )
    )
    |> account_no(p)
    |> external_id(p)
    |> rate(p, "nominalAnnualInterestRate")
    |> enum_in(p, "interestCompoundingPeriodType", SavingsEnums.compounding_ids())
    |> enum_in(p, "interestPostingPeriodType", SavingsEnums.posting_ids())
    |> enum_in(p, "interestCalculationType", SavingsEnums.calculation_ids())
    |> enum_in(p, "interestCalculationDaysInYearType", SavingsEnums.days_in_year_ids())
    |> opening_balance(p, mode)
    |> lockin(p, mode)
    |> boolean(p, "withdrawalFeeForTransfers")
    |> boolean(p, "withHoldTax")
    |> boolean(p, "allowOverdraft")
    |> amount(p, "overdraftLimit")
    |> amount(p, "nominalAnnualInterestRateOverdraft")
    |> amount(p, "minOverdraftForInterestCalculation")
    |> Validation.raise_if_errors!()
  end

  # the client (or group) and the product an application is for
  defp validate_references(v, p, mode) do
    client_id = Json.long(p, "clientId")
    group_id = Json.long(p, "groupId")

    v
    |> positive_if_given("clientId", client_id)
    |> positive_if_given("groupId", group_id)
    |> then(
      &if(mode == :create and client_id == nil and group_id == nil,
        do:
          &1
          |> Validation.param("clientId", client_id)
          |> Validation.not_null()
          |> Validation.greater_than_zero(),
        else: &1
      )
    )
    |> then(
      &if(mode == :create or Params.exists?(p, "productId"),
        do:
          &1
          |> Validation.param("productId", Json.long(p, "productId"))
          |> Validation.not_null()
          |> Validation.greater_than_zero(),
        else: &1
      )
    )
  end

  defp positive_if_given(v, _key, nil), do: v

  defp positive_if_given(v, key, id),
    do: v |> Validation.param(key, id) |> Validation.greater_than_zero()

  defp optional_positive(v, p, key) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Json.long(p, key))
        |> Validation.ignore_if_null()
        |> Validation.greater_than_zero(),
      else: v
  end

  defp account_no(v, p) do
    if Params.exists?(p, "accountNo"),
      do:
        v
        |> Validation.param("accountNo", Params.string(p, "accountNo"))
        |> Validation.not_blank()
        |> Validation.max_length(20),
      else: v
  end

  defp external_id(v, p) do
    if Params.exists?(p, "externalId"),
      do:
        v
        |> Validation.param("externalId", Params.string(p, "externalId"))
        |> Validation.max_length(100),
      else: v
  end

  defp rate(v, p, key) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Params.decimal_with_locale(p, key))
        |> Validation.not_null()
        |> Validation.zero_or_positive_amount(),
      else: v
  end

  defp amount(v, p, key) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Params.decimal_with_locale(p, key))
        |> Validation.ignore_if_null()
        |> Validation.zero_or_positive_amount(),
      else: v
  end

  defp enum_in(v, p, key, ids) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Params.integer_in_default_locale(p, key))
        |> Validation.not_null()
        |> Validation.one_of(ids),
      else: v
  end

  defp opening_balance(v, p, mode) do
    if Params.exists?(p, "minRequiredOpeningBalance") do
      v
      |> Validation.param(
        "minRequiredOpeningBalance",
        Params.decimal_with_locale(p, "minRequiredOpeningBalance")
      )
      |> then(&if(mode == :update, do: Validation.ignore_if_null(&1), else: &1))
      |> Validation.zero_or_positive_amount()
    else
      v
    end
  end

  defp lockin(v, p, _mode) do
    frequency =
      if Params.exists?(p, "lockinPeriodFrequency"),
        do: Params.integer_with_locale(p, "lockinPeriodFrequency")

    type =
      if Params.exists?(p, "lockinPeriodFrequencyType"),
        do: Params.integer_in_default_locale(p, "lockinPeriodFrequencyType")

    v =
      if Params.exists?(p, "lockinPeriodFrequency"),
        do:
          v
          |> Validation.param("lockinPeriodFrequency", frequency)
          |> Validation.zero_or_greater(),
        else: v

    if Params.exists?(p, "lockinPeriodFrequencyType"),
      do: v |> Validation.param("lockinPeriodFrequencyType", type) |> Validation.in_range(0, 3),
      else: v
  end

  defp boolean(v, p, key) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Params.boolean(p, key))
        |> Validation.ignore_if_null()
        |> Validation.true_or_false(),
      else: v
  end

  # what the account cannot do yet
  defp refuse_beyond_core!(p) do
    asked =
      [
        {"datatables", Params.exists?(p, "datatables")},
        {"lienAllowed", Params.boolean(p, "lienAllowed") == true},
        {"withHoldTax", Params.boolean(p, "withHoldTax") == true},
        {"isGSIM", Params.boolean(p, "isGSIM") == true},
        {"groupId", Json.long(p, "groupId") != nil and Json.long(p, "clientId") == nil}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if asked != [] do
      raise DomainRuleViolation,
        code: "error.msg.savingsaccount.feature.not.supported.yet",
        message:
          "These savings account settings are not supported yet by E-CoreBank: " <>
            Enum.join(asked, ", "),
        args: asked
    end
  end

  @doc false
  def client!(p) do
    case Json.long(p, "clientId") do
      nil ->
        nil

      id ->
        client = Clients.fetch!(id)
        if client.status_enum != Clients.status(:active), do: not_active!(id)
        client
    end
  end

  @doc false
  def not_active!(id) do
    raise DomainRuleViolation,
      code: "error.msg.client.not.active.exception",
      message: "The Client with id `#{id}` is not active",
      args: [id]
  end

  @doc false
  def staff!(p) do
    case Json.long(p, "fieldOfficerId") do
      nil -> nil
      id -> ECBOrg.Staff.fetch!(id)
    end
  end

  # --- the row ------------------------------------------------------------------------------------

  @doc false
  def new_row(user, p, product, client, staff, on) do
    now = DateTime.utc_now()
    allow_overdraft = given(p, "allowOverdraft", &Params.boolean/2, product.allow_overdraft)
    lock_type = lockin_type(p, product)

    %{
      account_no: blank_to_nil(Params.string(p, "accountNo")) || temporary_account_no(),
      external_id: blank_to_nil(Params.string(p, "externalId")),
      client_id: client && client.id,
      product_id: product.id,
      field_officer_id: staff && staff.id,
      status_enum: @pending,
      sub_status_enum: 0,
      account_type_enum: 1,
      deposit_type_enum: 100,
      submittedon_date: on,
      submittedon_userid: user.id,
      currency_code: product.currency.code,
      currency_digits: product.currency.decimal_places,
      currency_multiplesof: product.currency.multiples_of,
      nominal_annual_interest_rate:
        given(
          p,
          "nominalAnnualInterestRate",
          &Params.decimal_with_locale/2,
          product.nominal_annual_interest_rate
        ),
      interest_compounding_period_enum:
        given(
          p,
          "interestCompoundingPeriodType",
          &Params.integer_in_default_locale/2,
          product.compounding_id
        ),
      interest_posting_period_enum:
        given(
          p,
          "interestPostingPeriodType",
          &Params.integer_in_default_locale/2,
          product.posting_id
        ),
      interest_calculation_type_enum:
        given(
          p,
          "interestCalculationType",
          &Params.integer_in_default_locale/2,
          product.calculation_id
        ),
      interest_calculation_days_in_year_type_enum:
        given(
          p,
          "interestCalculationDaysInYearType",
          &Params.integer_in_default_locale/2,
          product.days_in_year_id
        ),
      min_required_opening_balance:
        given(
          p,
          "minRequiredOpeningBalance",
          &Params.decimal_with_locale/2,
          product.min_required_opening_balance
        ),
      lockin_period_frequency:
        given(
          p,
          "lockinPeriodFrequency",
          &Params.integer_with_locale/2,
          product.lockin_period_frequency
        ),
      lockin_period_frequency_enum: lock_type,
      withdrawal_fee_for_transfer: Params.boolean(p, "withdrawalFeeForTransfers") == true,
      allow_overdraft: allow_overdraft == true,
      overdraft_limit:
        zero_if_nil(
          zero_to_nil(
            given(p, "overdraftLimit", &Params.decimal_with_locale/2, product.overdraft_limit)
          )
        ),
      nominal_annual_interest_rate_overdraft:
        zero_if_nil(
          zero_to_nil(
            given(
              p,
              "nominalAnnualInterestRateOverdraft",
              &Params.decimal_with_locale/2,
              product.nominal_annual_interest_rate_overdraft
            )
          )
        ),
      min_overdraft_for_interest_calculation:
        zero_if_nil(
          zero_to_nil(
            given(
              p,
              "minOverdraftForInterestCalculation",
              &Params.decimal_with_locale/2,
              product.min_overdraft_for_interest_calculation
            )
          )
        ),
      account_balance_derived: Decimal.new(0),
      min_required_balance:
        zero_to_nil(
          given(
            p,
            "minRequiredBalance",
            &Params.decimal_with_locale/2,
            product.min_required_balance
          )
        ),
      enforce_min_required_balance:
        given(
          p,
          "enforceMinRequiredBalance",
          &Params.boolean/2,
          product.enforce_min_required_balance
        ) == true,
      min_balance_for_interest_calculation: product.min_balance_for_interest_calculation,
      withhold_tax: false,
      tax_group_id: product.tax_group && product.tax_group.id,
      is_lien_allowed: product.lien_allowed == true,
      max_allowed_lien_limit: product.max_allowed_lien_limit,
      version: 1,
      created_by: user.id,
      last_modified_by: user.id,
      created_on_utc: now,
      last_modified_on_utc: now
    }
  end

  # a value the application gives, or the product's
  defp given(p, key, reader, fallback),
    do: if(Params.exists?(p, key), do: reader.(p, key), else: fallback)

  defp lockin_type(p, product) do
    if Params.exists?(p, "lockinPeriodFrequencyType"),
      do: Params.integer_in_default_locale(p, "lockinPeriodFrequencyType"),
      else: product.lockin_type_id
  end

  defp zero_to_nil(%Decimal{} = d), do: if(Decimal.eq?(d, 0), do: nil, else: d)
  defp zero_to_nil(other), do: other

  defp zero_if_nil(nil), do: Decimal.new(0)
  defp zero_if_nil(d), do: d

  defp validate_application!(row, client, product) do
    on = row.submittedon_date
    v = Validation.new("savingsaccount.summital") |> Validation.param("submittedOnDate", on)

    cond do
      Date.compare(on, BusinessDate.current()) == :gt ->
        v
        |> Validation.fail_without_parameter("cannot.be.a.future.date")
        |> Validation.raise_if_errors!()

      client && client.activation_date && Date.compare(client.activation_date, on) == :gt ->
        v
        |> Validation.param("submittedOnDate", client.activation_date)
        |> Validation.fail_without_parameter("cannot.be.before.client.activation.date")
        |> Validation.raise_if_errors!()

      true ->
        :ok
    end

    limit = row.overdraft_limit

    if product.overdraft_limit != nil and Decimal.gt?(limit, product.overdraft_limit) do
      Validation.new("savingsaccount")
      |> Validation.param("overdraftLimit", limit)
      |> Validation.fail_with_code("cannot.exceed.product.value")
      |> Validation.raise_if_errors!()
    end
  end

  @doc false
  def insert!(row) do
    Integrity.translate(
      fn ->
        {1, [%{id: id}]} = TenantRepo.insert_all("m_savings_account", [row], returning: [:id])
        id
      end,
      %{},
      {"error.msg.savingsaccount.unknown.data.integrity.issue",
       "Unknown data integrity issue with savings account."}
    )
  end

  defp temporary_account_no,
    do: 19 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> binary_part(0, 19)

  # an account without a number of its own gets nine digits from its id, with the prefix the tenant's savings format
  # asks for
  @doc false
  def generate_account_no!(id, product, client) do
    format =
      TenantRepo.one(
        from(f in "c_account_number_format",
          where: f.account_type_enum == 3,
          select: %{prefix: f.prefix_type_enum, character: f.prefix_character}
        )
      )

    padded = String.pad_leading(Integer.to_string(id), 9, "0")

    account_no =
      case format do
        %{prefix: 1} -> prefixed(office_name(client), padded)
        %{prefix: 201} -> prefixed(product.short_name, padded)
        %{prefix: 401, character: char} -> fixed_prefix(char, id)
        _ -> padded
      end

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [account_no: account_no]
    )
  end

  defp office_name(%{office_id: office_id}),
    do: TenantRepo.one(from(o in "m_office", where: o.id == ^office_id, select: o.name))

  defp prefixed(nil, padded), do: padded
  defp prefixed(prefix, padded), do: String.slice(prefix, 0, 10) <> padded

  defp fixed_prefix(char, id) do
    prefix = String.slice(char || "", 0, 10)
    prefix <> String.pad_leading(Integer.to_string(id), max(9 - String.length(prefix), 0), "0")
  end

  @doc false
  def blank_to_nil(nil), do: nil
  def blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: text)

  # --- changing an application -------------------------------------------------------------------

  @changeable [
    {"externalId", :external_id, :text},
    {"accountNo", :account_no, :text},
    {"productId", :product_id, :id},
    {"clientId", :client_id, :id},
    {"fieldOfficerId", :field_officer_id, :id},
    {"nominalAnnualInterestRate", :nominal_annual_interest_rate, :decimal},
    {"interestCompoundingPeriodType", :interest_compounding_period_enum, :integer},
    {"interestPostingPeriodType", :interest_posting_period_enum, :integer},
    {"interestCalculationType", :interest_calculation_type_enum, :integer},
    {"interestCalculationDaysInYearType", :interest_calculation_days_in_year_type_enum, :integer}
  ]

  @doc "Changes what an application that is awaiting approval says."
  @spec modify!(struct, integer, Params.t()) :: Result.t()
  def modify!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    validate!(p, :update)
    refuse_beyond_core!(p)

    account = Savings.fetch!(id)
    check_client_active!(account)

    if account.status_enum != @pending do
      Validation.new("savingsaccount.modify")
      |> Validation.fail_without_parameter("not.in.submittedandpendingapproval.state")
      |> Map.update!(:errors, fn [e | rest] -> [Map.put(e, :parameter, nil) | rest] end)
      |> Validation.raise_if_errors!()
    end

    {changes, set} = changes(p, account)

    if changes != %{} do
      check_references!(p, changes)

      set =
        Keyword.merge(set, last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now())

      Integrity.translate(
        fn ->
          TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id), set: set)
        end,
        %{},
        {"error.msg.savingsaccount.unknown.data.integrity.issue",
         "Unknown data integrity issue with savings account."}
      )
    end

    client = Clients.fetch!(Keyword.get(set, :client_id, account.client_id))

    Result.new(
      resource_id: id,
      savings_id: id,
      office_id: client.office_id,
      client_id: client.id,
      changes: changes
    )
  end

  defp check_client_active!(%{client_id: client_id, status_enum: _} = _account)
       when is_nil(client_id),
       do: :ok

  defp check_client_active!(%{client_id: client_id}) do
    client = Clients.fetch!(client_id)
    if client.status_enum != Clients.status(:active), do: not_active!(client_id)
  end

  # the references a change names must exist
  defp check_references!(p, changes) do
    if Map.has_key?(changes, "productId"), do: SavingsProducts.fetch!(Json.long(p, "productId"))

    if Map.has_key?(changes, "clientId") and Json.long(p, "clientId") != nil do
      client = Clients.fetch!(Json.long(p, "clientId"))
      if client.status_enum != Clients.status(:active), do: not_active!(client.id)
    end

    if Map.has_key?(changes, "fieldOfficerId") and Json.long(p, "fieldOfficerId") != nil,
      do: ECBOrg.Staff.fetch!(Json.long(p, "fieldOfficerId"))

    :ok
  end

  defp changes(p, account) do
    @changeable
    |> Enum.filter(fn {key, _column, _kind} -> Params.exists?(p, key) end)
    |> Enum.map(fn {key, column, kind} ->
      {key, column, read(p, key, kind), Map.get(account, column), kind}
    end)
    |> Enum.filter(fn {_key, _column, new, old, kind} -> differs?(new, old, kind) end)
    |> Enum.reduce({%{}, []}, fn {key, column, new, _old, _kind}, {changes, set} ->
      {Map.put(changes, key, new), Keyword.put(set, column, new)}
    end)
  end

  defp read(p, key, :text), do: Params.string(p, key)
  defp read(p, key, :id), do: Json.long(p, key)
  defp read(p, key, :decimal), do: Params.decimal_with_locale(p, key)
  defp read(p, key, :integer), do: Params.integer_in_default_locale(p, key)

  defp differs?(new, old, :decimal),
    do: not (new != nil and old != nil and Decimal.eq?(new, old)) and new != old

  defp differs?(new, old, _kind), do: new != old

  # --- deleting -------------------------------------------------------------------------------------

  @doc "Deletes an application that is awaiting approval."
  @spec delete!(struct, integer) :: Result.t()
  def delete!(_user, id) do
    account = Savings.fetch!(id)
    check_client_active!(account)

    if account.status_enum != @pending do
      Validation.new("savingsaccount.delete")
      |> Validation.param("activatedOnDate", nil)
      |> Validation.fail_without_parameter("not.in.submittedandpendingapproval.state")
      |> Validation.raise_if_errors!()
    end

    TenantRepo.delete_all(from(n in "m_note", where: n.savings_account_id == ^id))

    TenantRepo.delete_all(
      from(h in "m_savings_officer_assignment_history", where: h.account_id == ^id)
    )

    TenantRepo.delete_all(from(a in "m_savings_account", where: a.id == ^id))
    client = Clients.fetch!(account.client_id)
    Result.new(resource_id: id, savings_id: id, office_id: client.office_id, client_id: client.id)
  end

  @doc false
  def invalid_number(key, value), do: %InvalidNumber{parameter: key, value: to_string(value)}
end
