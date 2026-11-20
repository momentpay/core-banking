defmodule ECBDeposits.Savings.Journal do
  @moduledoc """
  The journal entries the transactions of a savings account leave in the books, after Fineract's
  `CashBasedAccountingProcessorForSavings` and `AccrualBasedAccountingProcessorForSavings`: a deposit debits the
  account that money comes in to (the savings reference, or the fund source mapped to the payment type) and credits
  the savings control account; a withdrawal does the opposite. A product without accounting posts nothing. Undoing a
  transaction posts its entries again the other way round; a reversal that stands for a transaction posts nothing
  of its own. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.{Closures, ProductMappings}
  alias ECBPlatform.{BusinessDate, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @credit 1
  @debit 2
  @entity_savings 2

  @savings_reference 1
  @savings_control 2
  @interest_on_savings 3
  @income_from_fees 4
  @income_from_penalties 5
  @overdraft_control 11
  @income_from_interest 12
  @interest_payable 17
  @escheat_liability 14

  @doc "Posts the entries of a deposit or a withdrawal: `tx` carries `id`, `type`, `date`, `amount`, `payment_detail_id` and, when the transaction takes the
  account into overdraft or pays it back, `overdraft`, the part of the amount that does."
  @spec post!(struct, map, map) :: :ok
  def post!(_user, %{accounting_type: rule}, _tx) when rule in [nil, 1], do: :ok

  def post!(user, account, %{type: 3} = tx) do
    accounts = accounts(account.product_id)
    over = Map.get(tx, :overdraft, Decimal.new(0))
    rest = Decimal.sub(tx.amount, over)

    lines =
      cond do
        Decimal.lte?(tx.amount, 0) ->
          []

        Decimal.gt?(over, 0) ->
          [
            {@debit, accounts[@interest_on_savings], over},
            {@credit, accounts[@overdraft_control], over}
          ] ++
            interest_rest(accounts, rest)

        account.accounting_type in [3, 4] ->
          [
            {@debit, accounts[@interest_payable], tx.amount},
            {@credit, accounts[@savings_control], tx.amount}
          ]

        true ->
          interest_rest(accounts, tx.amount)
      end

    insert!(user, account, tx, lines)
  end

  # a fee, a penalty or a withdrawal fee paid: the savings control account pays the account the charge earns into (the
  # charge's own, or the one the product maps it to, or the product's for fees or penalties)
  def post!(user, account, %{type: type, charge: charge} = tx) when type in [4, 5, 7] do
    accounts = accounts(account.product_id)
    income = charge_income(account.product_id, charge, accounts)
    control = accounts[@savings_control]
    over = Map.get(tx, :overdraft, Decimal.new(0))
    rest = Decimal.sub(tx.amount, over)

    lines =
      if Decimal.gt?(over, 0) do
        [{@debit, accounts[@overdraft_control], over}, {@credit, income, over}] ++
          if(Decimal.gt?(rest, 0),
            do: [{@debit, control, rest}, {@credit, income, rest}],
            else: []
          )
      else
        [{@debit, control, tx.amount}, {@credit, income, tx.amount}]
      end

    insert!(user, account, tx, lines)
  end

  # what an overdraft owes is charged to the savings reference account, as income from interest
  def post!(user, account, %{type: 17} = tx) do
    accounts = accounts(account.product_id)

    insert!(user, account, tx, [
      {@debit, accounts[@savings_reference], tx.amount},
      {@credit, accounts[@income_from_interest], tx.amount}
    ])
  end

  def post!(user, account, %{type: 19} = tx) do
    accounts = accounts(account.product_id)

    insert!(user, account, tx, [
      {@debit, accounts[@savings_control], tx.amount},
      {@credit, accounts[@escheat_liability], tx.amount}
    ])
  end

  def post!(user, account, tx) do
    accounts = accounts(account.product_id)
    fund = fund_source(account.product_id, accounts, payment_type_id(tx))
    control = accounts[@savings_control]
    overdraft = accounts[@overdraft_control]
    over = Map.get(tx, :overdraft, Decimal.new(0))
    rest = Decimal.sub(tx.amount, over)

    lines =
      case {tx.type, Decimal.gt?(over, 0)} do
        {1, false} ->
          [{@debit, fund, tx.amount}, {@credit, control, tx.amount}]

        {2, false} ->
          [{@debit, control, tx.amount}, {@credit, fund, tx.amount}]

        {1, true} ->
          [{@debit, fund, over}, {@credit, overdraft, over}] ++ deposit_rest(fund, control, rest)

        {2, true} ->
          [{@debit, overdraft, over}, {@credit, fund, over}] ++
            withdrawal_rest(fund, control, rest)
      end

    insert!(user, account, tx, lines)
  end

  defp charge_income(product_id, charge, accounts) do
    cond do
      charge[:gl_account_id] ->
        charge.gl_account_id

      mapped = mapped_charge_account(product_id, charge) ->
        mapped

      true ->
        accounts[if(charge.penalty == true, do: @income_from_penalties, else: @income_from_fees)]
    end
  end

  defp mapped_charge_account(product_id, charge) do
    ProductMappings.saving()
    |> ProductMappings.charges(product_id, charge.penalty == true)
    |> Enum.find(&(&1.charge.id == charge.id))
    |> then(&(&1 && &1.account.id))
  end

  defp interest_rest(accounts, rest),
    do:
      if(Decimal.gt?(rest, 0),
        do: [
          {@debit, accounts[@interest_on_savings], rest},
          {@credit, accounts[@savings_control], rest}
        ],
        else: []
      )

  # what goes beyond the overdraft goes through the savings control account
  defp deposit_rest(fund, control, rest),
    do: if(Decimal.gt?(rest, 0), do: [{@debit, fund, rest}, {@credit, control, rest}], else: [])

  defp withdrawal_rest(fund, control, rest),
    do: if(Decimal.gt?(rest, 0), do: [{@debit, control, rest}, {@credit, fund, rest}], else: [])

  @doc "Posts the entries of transaction `tx_id` again the other way round, as undoing it does."
  @spec reverse!(struct, map, integer) :: :ok
  def reverse!(_user, %{accounting_type: rule}, _tx_id) when rule in [nil, 1], do: :ok

  def reverse!(user, account, tx_id) do
    originals =
      TenantRepo.all(
        from(j in "acc_gl_journal_entry",
          where: j.savings_transaction_id == ^tx_id and j.manual_entry == false,
          order_by: [desc: j.id],
          select: %{
            account_id: j.account_id,
            office_id: j.office_id,
            currency_code: j.currency_code,
            transaction_id: j.transaction_id,
            entry_date: j.entry_date,
            type_enum: j.type_enum,
            amount: j.amount,
            payment_details_id: j.payment_details_id
          }
        )
      )

    now = DateTime.utc_now()

    for o <- originals do
      row =
        Map.merge(o, %{
          savings_transaction_id: tx_id,
          reversed: false,
          manual_entry: false,
          type_enum: if(o.type_enum == @debit, do: @credit, else: @debit),
          entity_type_enum: @entity_savings,
          entity_id: account.id,
          created_by: user.id,
          last_modified_by: user.id,
          is_running_balance_calculated: false,
          office_running_balance: Decimal.new(0),
          organization_running_balance: Decimal.new(0),
          created_on_utc: now,
          last_modified_on_utc: now,
          submitted_on_date: BusinessDate.current()
        })

      TenantRepo.insert_all("acc_gl_journal_entry", [row])
    end

    :ok
  end

  defp accounts(product_id) do
    ProductMappings.saving()
    |> ProductMappings.regular(product_id)
    |> Map.new(&{&1.placeholder, &1.account.id})
  end

  defp payment_type_id(%{payment_detail_id: nil}), do: nil

  defp payment_type_id(%{payment_detail_id: id}),
    do:
      TenantRepo.one(from(d in "m_payment_detail", where: d.id == ^id, select: d.payment_type_id))

  defp fund_source(product_id, accounts, payment_type_id) do
    mapped =
      payment_type_id &&
        ProductMappings.saving()
        |> ProductMappings.payment_types(product_id)
        |> Enum.find(&(&1.payment_type.id == payment_type_id))

    if mapped, do: mapped.account.id, else: accounts[@savings_reference]
  end

  # a transaction made and reversed in one go leaves only the reverse of its entries: each pair of lines the other way
  # round, the line that was the credit first
  defp insert!(user, account, %{reversed: true} = tx, lines),
    do:
      insert!(
        user,
        account,
        Map.delete(tx, :reversed),
        lines |> Enum.chunk_every(2) |> Enum.flat_map(&flip_pair/1)
      )

  defp insert!(user, account, tx, lines) do
    check_not_closed!(account.client_office_id, tx.date)
    now = DateTime.utc_now()

    # one at a time, so the entries take their ids in the order Fineract posts them
    for {type, account_id, amount} <- lines, Decimal.compare(amount, 0) == :gt do
      TenantRepo.insert_all("acc_gl_journal_entry", [
        %{
          account_id: account_id,
          office_id: account.client_office_id,
          currency_code: account.currency_code,
          transaction_id: "S#{tx.id}",
          savings_transaction_id: tx.id,
          reversed: false,
          manual_entry: false,
          entry_date: tx.date,
          type_enum: type,
          amount: amount,
          entity_type_enum: @entity_savings,
          entity_id: account.id,
          created_by: user.id,
          last_modified_by: user.id,
          is_running_balance_calculated: false,
          office_running_balance: Decimal.new(0),
          organization_running_balance: Decimal.new(0),
          payment_details_id: tx.payment_detail_id,
          created_on_utc: now,
          last_modified_on_utc: now,
          submitted_on_date: BusinessDate.current()
        }
      ])
    end

    :ok
  end

  defp flip_pair(pair),
    do:
      pair
      |> Enum.reverse()
      |> Enum.map(fn {type, account_id, amount} ->
        {if(type == @debit, do: @credit, else: @debit), account_id, amount}
      end)

  defp check_not_closed!(office_id, date) do
    closed = Closures.closed_until(office_id)

    if closed && Date.compare(closed, date) != :lt do
      raise DomainRuleViolation,
        code: "error.msg.glJournalEntry.invalid.accounting.closed",
        message: "Journal entry cannot be made prior to last account closing date for the branch",
        args: [Date.to_iso8601(closed), nil, nil]
    end
  end
end
