defmodule ECBLoans.Loans.Journal do
  @moduledoc """
  The journal entries a loan's transactions leave in the books, for a product with cash accounting
  (Fineract's `CashBasedAccountingProcessorForLoan`).

    * a disbursement debits the loan portfolio and credits the fund source;
    * a repayment credits the loan portfolio (principal), the income from interest, from fees and from
      penalties, and the overpayment liability, and debits the fund source for the whole amount.

  The fund source is the account mapped to the payment type of the transaction, or else the product's own
  fund-source account. A line of nothing is not posted. A product without accounting posts nothing. Interest
  that is accrued but not yet paid is no business of cash accounting, so accrual transactions post nothing.
  Products with accrual accounting are refused before a transaction is made (`supported?/1`).
  """
  import Ecto.Query

  alias ECBLedger.{Closures, ProductMappings}
  alias ECBPlatform.{BusinessDate, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @credit 1
  @debit 2
  @entity_loan 1

  @fund_source 1
  @loan_portfolio 2
  @interest_on_loans 3
  @income_from_fees 4
  @income_from_penalties 5
  @losses_written_off 6
  @overpayment 11

  @doc "Whether loans of the product can be posted: accounting off or cash. Accrual accounting is not built yet."
  @spec supported?(map) :: boolean
  def supported?(%{accounting_id: id}), do: id in [nil, 1, 2]

  @doc "Refuses a product whose accounting is not built yet, with Fineract's own wording for what is missing."
  @spec check_supported!(map, String.t()) :: :ok
  def check_supported!(product, what) do
    if supported?(product) do
      :ok
    else
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "#{what} on a loan of a product with accrual accounting is not supported yet by E-CoreBank " <>
            "(its journal entries are not built)",
        args: ["accountingRule"]
    end
  end

  @doc "Posts the entries of a disbursement."
  @spec disbursement!(struct, map, map, map) :: :ok
  def disbursement!(_user, _loan, %{accounting_id: id}, _tx) when id in [nil, 1], do: :ok

  def disbursement!(user, loan, product, tx) do
    accounts = accounts(product)
    fund = fund_source(product, accounts, payment_type_id(tx))

    post!(user, loan, tx, [
      {@debit, accounts[@loan_portfolio], tx.amount},
      {@credit, fund, tx.amount}
    ])
  end

  @doc "Posts the entries of a repayment: `tx` carries `amount` and the `principal`, `interest`, `fees`, `penalties` and `overpayment` portions."
  @spec repayment!(struct, map, map, map) :: :ok
  def repayment!(_user, _loan, %{accounting_id: id}, _tx) when id in [nil, 1], do: :ok

  def repayment!(user, loan, product, tx) do
    accounts = accounts(product)
    fund = fund_source(product, accounts, payment_type_id(tx))

    post!(user, loan, tx, [
      {@credit, accounts[@loan_portfolio], tx.principal},
      {@credit, accounts[@interest_on_loans], tx.interest},
      {@credit, accounts[@income_from_fees], tx.fees},
      {@credit, accounts[@income_from_penalties], tx.penalties},
      {@credit, accounts[@overpayment], tx.overpayment},
      {@debit, fund, tx.amount}
    ])
  end

  @doc "Posts the entries of a write-off: the principal written off is a loss and leaves the loan portfolio."
  @spec write_off!(struct, map, map, map) :: :ok
  def write_off!(_user, _loan, %{accounting_id: id}, _tx) when id in [nil, 1], do: :ok

  def write_off!(user, loan, product, tx) do
    accounts = accounts(product)

    post!(user, loan, tx, [
      {@debit, accounts[@losses_written_off], tx.principal},
      {@credit, accounts[@loan_portfolio], tx.principal}
    ])
  end

  @doc "Takes a transaction's entries back with entries of the opposite kind, as Fineract does when a transaction is undone."
  @spec reverse!(struct, map, integer, Date.t()) :: :ok
  def reverse!(user, loan, tx_id, _date) do
    now = DateTime.utc_now()

    originals =
      TenantRepo.all(
        from(j in "acc_gl_journal_entry",
          where: j.loan_transaction_id == ^tx_id and j.manual_entry == false,
          order_by: j.id,
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

    for o <- originals do
      row =
        Map.merge(o, %{
          loan_transaction_id: tx_id,
          reversed: false,
          manual_entry: false,
          type_enum: if(o.type_enum == @debit, do: @credit, else: @debit),
          entity_type_enum: @entity_loan,
          entity_id: loan.id,
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

  # --- the product's accounts ---------------------------------------------------------------------

  defp accounts(product) do
    product.id
    |> then(&ProductMappings.regular(ProductMappings.loan(), &1))
    |> Map.new(&{&1.placeholder, &1.account.id})
  end

  defp payment_type_id(%{payment_detail_id: nil}), do: nil

  defp payment_type_id(%{payment_detail_id: id}),
    do:
      TenantRepo.one(from(d in "m_payment_detail", where: d.id == ^id, select: d.payment_type_id))

  defp payment_type_id(_tx), do: nil

  defp fund_source(product, accounts, payment_type_id) do
    mapped =
      payment_type_id &&
        ProductMappings.payment_types(ProductMappings.loan(), product.id)
        |> Enum.find(&(&1.payment_type.id == payment_type_id))

    if mapped, do: mapped.account.id, else: accounts[@fund_source]
  end

  # --- posting ------------------------------------------------------------------------------------

  defp post!(user, loan, tx, lines) do
    check_not_closed!(loan.client_office_id, tx.date)
    now = DateTime.utc_now()

    rows =
      for {type, account_id, amount} <- lines, amount != nil, Decimal.compare(amount, 0) == :gt do
        %{
          account_id: account_id,
          office_id: loan.client_office_id,
          currency_code: loan.currency_code,
          transaction_id: "L#{tx.id}",
          loan_transaction_id: tx.id,
          reversed: false,
          manual_entry: false,
          entry_date: tx.date,
          type_enum: type,
          amount: amount,
          entity_type_enum: @entity_loan,
          entity_id: loan.id,
          created_by: user.id,
          last_modified_by: user.id,
          is_running_balance_calculated: false,
          office_running_balance: Decimal.new(0),
          organization_running_balance: Decimal.new(0),
          payment_details_id: tx[:payment_detail_id],
          created_on_utc: now,
          last_modified_on_utc: now,
          submitted_on_date: BusinessDate.current()
        }
      end

    # one at a time, so the entries take their ids in the order Fineract posts them
    Enum.each(rows, &TenantRepo.insert_all("acc_gl_journal_entry", [&1]))
    :ok
  end

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
