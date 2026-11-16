defmodule ECBLoans.Loans.Journal do
  @moduledoc """
  The journal entries a loan's transactions leave in the books, following Fineract's
  `CashBasedAccountingProcessorForLoan` and `AccrualBasedAccountingProcessorForLoan`.

  With cash accounting (rule 2):

    * a disbursement debits the loan portfolio and credits the fund source;
    * a repayment credits the loan portfolio (principal), the income from interest, from fees and from
      penalties, and the overpayment liability, and debits the fund source for the whole amount;
    * interest that is accrued but not yet paid is no business of cash accounting, so accrual transactions
      and waivers post nothing.

  With accrual accounting (rules 3 and 4, periodic and upfront) income is booked when it is earned:

    * an accrual transaction debits the receivable of the interest (and of fees and penalties) and credits
      the income from it;
    * a repayment credits the portfolio and the receivables, so that what was accrued is settled, and debits
      the fund source;
    * a waiver or a write-off credits the portfolio and the receivables and debits the account of losses
      written off, for the whole amount.

  The fund source is the account mapped to the payment type of the transaction, or else the product's own
  fund-source account. A line of nothing is not posted, and lines on the same account are one entry. A product
  without accounting posts nothing.
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
  @interest_receivable 7
  @fees_receivable 8
  @penalties_receivable 9

  @doc "Whether loans of the product can be posted: every accounting rule Fineract has is built."
  @spec supported?(map) :: boolean
  def supported?(%{accounting_id: id}), do: id in [nil, 1, 2, 3, 4]

  @doc "Refuses a product whose accounting rule is not known, so that nothing is paid out without its entries."
  @spec check_supported!(map, String.t()) :: :ok
  def check_supported!(product, what) do
    if supported?(product) do
      :ok
    else
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "#{what} on a loan of a product with this accounting rule is not supported yet by E-CoreBank",
        args: ["accountingRule"]
    end
  end

  @doc "Whether the product books its income as it is earned (accrual accounting)."
  @spec accrual?(map) :: boolean
  def accrual?(%{accounting_id: id}), do: id in [3, 4]

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

    if accrual?(product) do
      credits =
        merged([
          {@credit, accounts[@loan_portfolio], tx.principal},
          {@credit, accounts[@interest_receivable], tx.interest},
          {@credit, fee_account(accounts, tx), tx.fees},
          {@credit, accounts[@penalties_receivable], tx.penalties},
          {@credit, accounts[@overpayment], tx.overpayment}
        ])

      post!(user, loan, tx, credits ++ [{@debit, fund, tx.amount}])
    else
      post!(user, loan, tx, [
        {@credit, accounts[@loan_portfolio], tx.principal},
        {@credit, accounts[@interest_on_loans], tx.interest},
        {@credit, accounts[@income_from_fees], tx.fees},
        {@credit, accounts[@income_from_penalties], tx.penalties},
        {@credit, accounts[@overpayment], tx.overpayment},
        {@debit, fund, tx.amount}
      ])
    end
  end

  @doc """
  Posts the entries of an accrual: the interest, fees and penalties earned are receivable, and income. Cash
  accounting does not book what is not yet paid.
  """
  @spec accrual!(struct, map, map, map) :: :ok
  def accrual!(user, loan, product, tx) do
    if accrual?(product) do
      accounts = accounts(product)

      post!(user, loan, tx, [
        {@debit, accounts[@interest_receivable], tx[:interest]},
        {@credit, accounts[@interest_on_loans], tx[:interest]},
        {@debit, accounts[@fees_receivable], tx[:fees]},
        {@credit, accounts[@income_from_fees], tx[:fees]},
        {@debit, accounts[@penalties_receivable], tx[:penalties]},
        {@credit, accounts[@income_from_penalties], tx[:penalties]}
      ])
    else
      :ok
    end
  end

  @doc "Posts the entries of an interest waiver: with accrual accounting the interest receivable is a loss."
  @spec waive_interest!(struct, map, map, map) :: :ok
  def waive_interest!(user, loan, product, tx) do
    if accrual?(product), do: write_off!(user, loan, product, tx), else: :ok
  end

  @doc "Posts the entries of a write-off: what is written off leaves the books as a loss."
  @spec write_off!(struct, map, map, map) :: :ok
  def write_off!(_user, _loan, %{accounting_id: id}, _tx) when id in [nil, 1], do: :ok

  def write_off!(user, loan, product, tx) do
    accounts = accounts(product)

    if accrual?(product) do
      total =
        [:principal, :interest, :fees, :penalties]
        |> Enum.map(&(tx[&1] || Decimal.new(0)))
        |> Enum.reduce(&Decimal.add/2)

      credits =
        merged([
          {@credit, accounts[@loan_portfolio], tx[:principal]},
          {@credit, accounts[@interest_receivable], tx[:interest]},
          {@credit, accounts[@fees_receivable], tx[:fees]},
          {@credit, accounts[@penalties_receivable], tx[:penalties]}
        ])

      post!(user, loan, tx, credits ++ [{@debit, accounts[@losses_written_off], total}])
    else
      post!(user, loan, tx, [
        {@debit, accounts[@losses_written_off], tx.principal},
        {@credit, accounts[@loan_portfolio], tx.principal}
      ])
    end
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

  # fees paid when the loan is paid out go straight to income; later fees settle what was receivable
  defp fee_account(accounts, %{income_from_fees: true}), do: accounts[@income_from_fees]
  defp fee_account(accounts, _tx), do: accounts[@fees_receivable]

  # lines on the same account and of the same kind are one entry, at the place of the first
  defp merged(lines) do
    lines
    |> Enum.reject(fn {_type, _account, amount} -> amount == nil end)
    |> Enum.reduce([], &merge_line/2)
  end

  defp merge_line({type, account, amount}, acc) do
    case Enum.find_index(acc, &match?({^type, ^account, _}, &1)) do
      nil -> acc ++ [{type, account, amount}]
      at -> List.update_at(acc, at, &add_amount(&1, amount))
    end
  end

  defp add_amount({type, account, sum}, amount), do: {type, account, Decimal.add(sum, amount)}

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
