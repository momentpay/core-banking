defmodule ECBLedger.ProductMappings do
  @moduledoc """
  Which general-ledger account each kind of product money goes to (`acc_product_mapping`), following
  Fineract's `ProductToGLAccountMappingHelper` and its repository. Savings products and loan products share
  this table: a mapping belongs to a product of a *product type* (1 loan, 2 saving), names the *placeholder*
  it fills (savings control, income from fees, ...), and may be narrowed to one payment type (placeholder 1,
  the fund source) or one charge (4 fees, 5 penalties).

  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.GLAccounts
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.TenantRepo

  @loan 1
  @saving 2

  @fund_source 1
  @income_from_fees 4
  @income_from_penalties 5

  @asset 1
  @liability 2
  @income 4
  @expense 5

  # mappings a product may lack, which are then created rather than refused
  @optional_params ["interestReceivableAccountId"]

  @type_names %{1 => "ASSET", 2 => "LIABILITY", 3 => "EQUITY", 4 => "INCOME", 5 => "EXPENSE"}

  @doc "The product type of loans."
  def loan, do: @loan

  @doc "The product type of savings."
  def saving, do: @saving

  @doc "The account type numbers: `:asset`, `:liability`, `:income` and `:expense`."
  def account_type(:asset), do: @asset
  def account_type(:liability), do: @liability
  def account_type(:income), do: @income
  def account_type(:expense), do: @expense

  # --- reads ----------------------------------------------------------------------------------

  defp base do
    from(m in "acc_product_mapping",
      join: a in "acc_gl_account",
      on: a.id == m.gl_account_id,
      select: %{
        id: m.id,
        placeholder: m.financial_account_type,
        payment_type_id: m.payment_type,
        charge_id: m.charge_id,
        account: %{id: a.id, name: a.name, gl_code: a.gl_code, type: a.classification_enum}
      },
      order_by: m.id
    )
  end

  @doc "The mappings that are neither narrowed to a payment type nor a charge, nor to a reason or classification."
  @spec regular(integer, integer) :: [map]
  def regular(product_type, product_id) do
    base()
    |> where([m], m.product_id == ^product_id and m.product_type == ^product_type)
    |> where(
      [m],
      is_nil(m.charge_id) and is_nil(m.payment_type) and is_nil(m.charge_off_reason_id) and
        is_nil(m.write_off_reason_id) and is_nil(m.capitalized_income_classification_id) and
        is_nil(m.buydown_fee_classification_id)
    )
    |> TenantRepo.all()
  end

  @doc "The fund-source mappings: one account per payment type (nothing when there are none)."
  @spec payment_types(integer, integer) :: [map]
  def payment_types(product_type, product_id) do
    from([m, a] in base(),
      join: p in "m_payment_type",
      on: p.id == m.payment_type,
      where:
        m.product_id == ^product_id and m.product_type == ^product_type and
          m.financial_account_type == ^@fund_source,
      select_merge: %{payment_type: %{id: p.id, name: p.value}}
    )
    |> TenantRepo.all()
  end

  @doc "The income account of each charge, for fees or penalties (as the charge says it is one)."
  @spec charges(integer, integer, boolean) :: [map]
  def charges(product_type, product_id, penalty?) do
    from([m, a] in base(),
      join: c in "m_charge",
      on: c.id == m.charge_id,
      where:
        m.product_id == ^product_id and m.product_type == ^product_type and
          c.is_penalty == ^penalty?,
      select_merge: %{charge: %{id: c.id, name: c.name, penalty: c.is_penalty}}
    )
    |> TenantRepo.all()
  end

  # --- writes: one account for a placeholder -----------------------------------------------------

  @doc """
  Maps `placeholder` of a product to the account `account_id`, which must be of one of `types`. Nothing is
  done when no account was named.
  """
  @spec save_account!(integer, integer, String.t(), integer | nil, integer, [integer]) :: :ok
  def save_account!(_type, _product, _param, nil, _placeholder, _types), do: :ok

  def save_account!(product_type, product_id, param, account_id, placeholder, types) do
    account = account_of_type!(param, account_id, types)
    insert!(product_type, product_id, placeholder, account.id, %{})
  end

  @doc """
  Changes the account mapped to `placeholder`, noting the new account in `changes` under `param`. A
  mapping that does not exist yet is an error, except for the placeholders in `optional`, which are
  created.
  """
  @spec merge_account!(
          integer,
          integer,
          String.t(),
          integer | nil,
          integer,
          String.t(),
          [integer],
          map
        ) ::
          map
  def merge_account!(_t, _p, _param, nil, _placeholder, _name, _types, changes), do: changes

  def merge_account!(
        product_type,
        product_id,
        param,
        account_id,
        placeholder,
        name,
        types,
        changes
      ) do
    case find_core(product_type, product_id, placeholder) do
      nil when param in @optional_params ->
        save_account!(product_type, product_id, param, account_id, placeholder, types)
        changes

      nil ->
        raise ResourceNotFound,
          code: "error.msg.productToAccountMapping.not.found",
          message:
            "Mapping for product of type #{type_name(product_type)} with Id #{product_id} does not exist for an account of type #{name}",
          args: [type_name(product_type), product_id, name]

      mapping ->
        change_account!(mapping, param, account_id, types, changes)
    end
  end

  @doc "Like `merge_account!/8`, but a missing mapping is created."
  @spec create_or_merge_account!(
          integer,
          integer,
          String.t(),
          integer | nil,
          integer,
          [integer],
          map
        ) ::
          map
  def create_or_merge_account!(_t, _p, _param, nil, _placeholder, _types, changes), do: changes

  def create_or_merge_account!(
        product_type,
        product_id,
        param,
        account_id,
        placeholder,
        types,
        changes
      ) do
    case find_core(product_type, product_id, placeholder) do
      nil ->
        account = account_of_type!(param, account_id, types)
        insert!(product_type, product_id, placeholder, account.id, %{})
        Map.put(changes, param, account_id)

      mapping ->
        change_account!(mapping, param, account_id, types, changes)
    end
  end

  defp change_account!(mapping, param, account_id, types, changes) do
    if mapping.account.id == account_id do
      changes
    else
      account = account_of_type!(param, account_id, types)

      TenantRepo.update_all(from(m in "acc_product_mapping", where: m.id == ^mapping.id),
        set: [gl_account_id: account.id]
      )

      Map.put(changes, param, account_id)
    end
  end

  defp find_core(product_type, product_id, placeholder) do
    Enum.find(regular(product_type, product_id), &(&1.placeholder == placeholder))
  end

  # --- writes: payment channels and charges -----------------------------------------------------

  @doc "Maps each payment type to its fund-source account (the mappings named in `pairs` as `{payment_type_id, account_id}`)."
  @spec save_payment_channels!(integer, integer, [{integer, integer}]) :: :ok
  def save_payment_channels!(product_type, product_id, pairs) do
    for {payment_type_id, account_id} <- pairs do
      unless TenantRepo.exists?(from(p in "m_payment_type", where: p.id == ^payment_type_id)) do
        raise ResourceNotFound,
          code: "error.msg.payment.type.invalid",
          message: "PaymentType with #{payment_type_id} does not exist",
          args: [payment_type_id]
      end

      account = GLAccounts.fetch!(account_id)

      insert!(product_type, product_id, @fund_source, account.id, %{payment_type: payment_type_id})
    end

    :ok
  end

  @doc "Brings the fund-source mappings in line with `pairs`: changed, added, and those not named removed."
  @spec update_payment_channels!(integer, integer, [{integer, integer}]) :: :ok
  def update_payment_channels!(product_type, product_id, pairs) do
    wanted = Map.new(pairs)

    existing =
      TenantRepo.all(
        from(m in "acc_product_mapping",
          where:
            m.product_id == ^product_id and m.product_type == ^product_type and
              m.financial_account_type == ^@fund_source and not is_nil(m.payment_type),
          order_by: m.id,
          select: %{id: m.id, payment_type: m.payment_type, account_id: m.gl_account_id}
        )
      )

    for row <- existing do
      case Map.fetch(wanted, row.payment_type) do
        {:ok, account_id} when account_id != row.account_id ->
          account = GLAccounts.fetch!(account_id)

          TenantRepo.update_all(from(m in "acc_product_mapping", where: m.id == ^row.id),
            set: [gl_account_id: account.id]
          )

        {:ok, _same} ->
          :ok

        :error ->
          TenantRepo.delete_all(from(m in "acc_product_mapping", where: m.id == ^row.id))
      end
    end

    kept = MapSet.new(existing, & &1.payment_type)

    save_payment_channels!(
      product_type,
      product_id,
      Enum.reject(pairs, fn {t, _} -> MapSet.member?(kept, t) end)
    )
  end

  @doc "Maps each charge to the income account its money goes to (`pairs` as `{charge_id, account_id}`)."
  @spec save_charge_accounts!(integer, integer, [{integer, integer}], boolean) :: :ok
  def save_charge_accounts!(product_type, product_id, pairs, penalty?) do
    for {charge_id, account_id} <- pairs do
      unless TenantRepo.exists?(from(c in "m_charge", where: c.id == ^charge_id)) do
        raise ResourceNotFound,
          code: "error.msg.charge.id.invalid",
          message: "Charge with identifier #{charge_id} does not exist",
          args: [charge_id]
      end

      {account, placeholder} = charge_account!(account_id, penalty?)
      insert!(product_type, product_id, placeholder, account.id, %{charge_id: charge_id})
    end

    :ok
  end

  defp charge_account!(account_id, true),
    do: {account_of_type!("incomeAccountId", account_id, [@income]), @income_from_penalties}

  defp charge_account!(account_id, false),
    do:
      {account_of_type!("incomeAccountId", account_id, [@income, @liability]), @income_from_fees}

  @doc "Brings the charge income mappings (fees or penalties) in line with `pairs`."
  @spec update_charge_accounts!(integer, integer, [{integer, integer}], boolean) :: :ok
  def update_charge_accounts!(product_type, product_id, pairs, penalty?) do
    placeholder = if penalty?, do: @income_from_penalties, else: @income_from_fees
    wanted = Map.new(pairs)

    existing =
      TenantRepo.all(
        from(m in "acc_product_mapping",
          where:
            m.product_id == ^product_id and m.product_type == ^product_type and
              m.financial_account_type == ^placeholder and not is_nil(m.charge_id),
          order_by: m.id,
          select: %{id: m.id, charge_id: m.charge_id, account_id: m.gl_account_id}
        )
      )

    for row <- existing do
      case Map.fetch(wanted, row.charge_id) do
        {:ok, account_id} when account_id != row.account_id ->
          {account, _} = charge_account!(account_id, penalty?)

          TenantRepo.update_all(from(m in "acc_product_mapping", where: m.id == ^row.id),
            set: [gl_account_id: account.id]
          )

        {:ok, _same} ->
          :ok

        :error ->
          TenantRepo.delete_all(from(m in "acc_product_mapping", where: m.id == ^row.id))
      end
    end

    kept = MapSet.new(existing, & &1.charge_id)

    save_charge_accounts!(
      product_type,
      product_id,
      Enum.reject(pairs, fn {c, _} -> MapSet.member?(kept, c) end),
      penalty?
    )
  end

  @doc "Removes every mapping of a product."
  @spec delete_all!(integer, integer) :: :ok
  def delete_all!(product_type, product_id) do
    TenantRepo.delete_all(
      from(m in "acc_product_mapping",
        where: m.product_id == ^product_id and m.product_type == ^product_type
      )
    )

    :ok
  end

  # --- shared ---------------------------------------------------------------------------------

  defp insert!(product_type, product_id, placeholder, account_id, extra) do
    row =
      Map.merge(
        %{
          gl_account_id: account_id,
          product_id: product_id,
          product_type: product_type,
          financial_account_type: placeholder
        },
        extra
      )

    TenantRepo.insert_all("acc_product_mapping", [row])
    :ok
  end

  # The account, which must be of one of `types`; otherwise Fineract's complaint naming the parameter.
  defp account_of_type!(param, account_id, types) do
    account = GLAccounts.fetch!(account_id)

    if account.type_id in types do
      account
    else
      expected =
        case types do
          [one] -> @type_names[one]
          many -> "[" <> Enum.join(many, ", ") <> "]"
        end

      raise DomainRuleViolation,
        code: "error.msg.#{param}.invalid.account.type",
        message:
          "Passed in GLAccount #{param} with Id #{account_id}maps to the account #{account.name} of type #{@type_names[account.type_id]}, the expected account type was one among #{expected}",
        args: [param, account_id, account.name, @type_names[account.type_id], expected]
    end
  end

  defp type_name(@loan), do: "LOAN"
  defp type_name(@saving), do: "SAVING"
end
