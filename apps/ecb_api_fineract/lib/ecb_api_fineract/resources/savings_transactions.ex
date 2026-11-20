defmodule ECBApiFineract.Resources.SavingsTransactions do
  @moduledoc """
  `/v1/savingsaccounts/:id/transactions`: the transactions of a savings account. The template, one transaction, making
  a deposit or a withdrawal and undoing, reversing or changing a transaction. Answers as Fineract's
  `SavingsAccountTransactionsApiResource` does.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{PaymentTypes, Read, SavingsAccounts, Write}
  alias ECBDeposits.Savings
  alias ECBDeposits.Savings.Transactions
  alias ECBOrg.PaymentTypes, as: OrgPaymentTypes
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Errors.{DomainRuleViolation, UnrecognizedQueryParameter}

  @resource "SAVINGSACCOUNT"

  # --- reads ----------------------------------------------------------------------------------

  @doc "`GET /savingsaccounts/:id/transactions/template`"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> id |> Savings.fetch!() |> template_json() end)
    end)
  end

  @doc "`GET /savingsaccounts/external-id/:external_id/transactions/template`"
  def template_by_external_id(conn, external_id) do
    Read.respond(conn, @resource, fn ->
      external_id |> account_by_external_id!() |> template_json()
    end)
  end

  defp template_json(a) do
    today = BusinessDate.current()

    %{
      "accountId" => a.id,
      "accountNo" => a.account_no,
      "date" => today,
      "currency" => SavingsAccounts.currency(a),
      "reversed" => false,
      "submittedOnDate" => today,
      "interestedPostedAsOn" => false,
      "isManualTransaction" => false,
      "lienTransaction" => false,
      "chargesPaidByData" => [],
      "paymentTypeOptions" => payment_type_options(),
      "isOverdraft" => false
    }
  end

  defp payment_type_options, do: Enum.map(OrgPaymentTypes.list(), &PaymentTypes.serialize/1)

  defp account_by_external_id!(external_id),
    do:
      Savings.get_by_external_id(external_id) ||
        raise(Savings.not_found_by_external_id_named(external_id))

  @doc "`GET /savingsaccounts/:id/transactions/:transaction_id`"
  def show(conn, raw_id, raw_tid) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, tid} <- Write.path_id(raw_tid) do
      Read.respond(conn, @resource, fn ->
        a = Savings.fetch!(id)
        tx = Transactions.get(id, tid) || raise(Transactions.not_found(id, tid))
        one(a, tx, conn.query_params)
      end)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "`GET /savingsaccounts/:id/transactions/external-id/:external_id`"
  def show_by_external_id(conn, raw_id, external_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        a = Savings.fetch!(id)

        tx =
          Transactions.get_by_external_id(id, external_id) ||
            raise(Transactions.not_found_by_external_id(id, external_id))

        one(a, tx, conn.query_params)
      end)
    end)
  end

  @doc "`GET /savingsaccounts/external-id/:external_id/transactions/:transaction_id`"
  def show_of_external_account(conn, external_id, raw_tid) do
    Write.with_path_id(conn, raw_tid, fn tid ->
      Read.respond(conn, @resource, fn ->
        a = account_by_external_id!(external_id)
        tx = Transactions.get(a.id, tid) || raise(Transactions.not_found(a.id, tid))
        one(a, tx, conn.query_params)
      end)
    end)
  end

  defp one(a, tx, q) do
    body = json(tx, a, false)

    # with the template Fineract builds the answer anew, and it keeps no mind of reversals or holds
    if q["template"] == "true",
      do:
        body
        |> Map.drop(["isReversal", "originalTransactionId", "releaseTransactionId"])
        |> Map.put("paymentTypeOptions", payment_type_options()),
      else: body
  end

  @doc "The transactions of an account as an account shows them, every flag included."
  @spec list_json(map) :: [map]
  def list_json(a), do: Enum.map(Transactions.list(a.id), &json(&1, a, true))

  # a transaction as Fineract writes it: shorter when it comes alone, with every flag when it is part of an account
  defp json(t, a, full?) do
    type = t.transaction_type_enum
    reversed? = t.is_reversed == true
    reversal? = t.is_reversal == true

    base = %{
      "id" => t.id,
      "transactionType" => type_json(t.transaction_type_enum, full?),
      "entryType" => entry(type, reversal?),
      "accountId" => a.id,
      "accountNo" => a.account_no,
      "externalId" => t.external_id,
      "date" => t.transaction_date,
      "currency" => SavingsAccounts.currency(a),
      "paymentDetailData" => payment_detail(t),
      "amount" => t.amount,
      "runningBalance" => t.running_balance_derived || 0,
      "reversed" => reversed?,
      "submittedOnDate" => t.submitted_on_date,
      "interestedPostedAsOn" => t.is_manual == true,
      "submittedByUsername" => t.submitted_by_username,
      "note" => t.note,
      "isReversal" => reversal?,
      "originalTransactionId" => t.original_transaction_id || 0,
      "isManualTransaction" => false,
      "lienTransaction" => t.is_lien_transaction == true,
      "releaseTransactionId" => t.release_id_of_hold_amount || 0,
      "chargesPaidByData" => [],
      "isOverdraft" => false
    }

    # an account lists a transaction without external id with an explicit null; a single one leaves it out
    if full?,
      do:
        base
        |> Map.put("externalId", t.external_id || :null)
        |> Map.merge(flags(t, type, reversed?, reversal?)),
      else: base
  end

  defp payment_detail(%{payment_type_id: nil}), do: nil

  defp payment_detail(t) do
    %{
      "id" => t.id,
      "paymentType" => %{"id" => t.payment_type_id, "name" => t.payment_type_name},
      "accountNumber" => t.account_number,
      "checkNumber" => t.check_number,
      "routingCode" => t.routing_code,
      "receiptNumber" => t.receipt_number,
      "bankNumber" => t.bank_number
    }
  end

  # What each kind of transaction is called and which flags it carries. `credit?` is nil for a transaction that moves
  # no money (a waiver), `flags` the ones of the type that are on, `extra` the ones of the full type that are on.
  @types %{
    1 => %{
      code: "savingsAccountTransactionType.deposit",
      value: "Deposit",
      enum: "DEPOSIT",
      credit?: true,
      flags: ["deposit"],
      extra: ["depositOrWithdrawal"]
    },
    2 => %{
      code: "savingsAccountTransactionType.withdrawal",
      value: "Withdrawal",
      enum: "WITHDRAWAL",
      credit?: false,
      flags: ["withdrawal"],
      extra: ["depositOrWithdrawal"]
    },
    3 => %{
      code: "savingsAccountTransactionType.interestPosting",
      value: "Interest posting",
      enum: "INTEREST_POSTING",
      credit?: true,
      flags: ["interestPosting"],
      extra: []
    },
    4 => %{
      code: "savingsAccountTransactionType.withdrawalFee",
      value: "Withdrawal fee",
      enum: "WITHDRAWAL_FEE",
      credit?: false,
      flags: ["feeDeduction"],
      extra: ["withdrawalFee", "chargeTransaction"]
    },
    5 => %{
      code: "savingsAccountTransactionType.annualFee",
      value: "Annual fee",
      enum: "ANNUAL_FEE",
      credit?: false,
      flags: ["feeDeduction"],
      extra: ["annualFee", "chargeTransaction"]
    },
    6 => %{
      code: "savingsAccountTransactionType.waiveCharge",
      value: "Waive Charge",
      enum: "WAIVE_CHARGES",
      credit?: nil,
      flags: [],
      extra: []
    },
    7 => %{
      code: "savingsAccountTransactionType.payCharge",
      value: "Pay Charge",
      enum: "PAY_CHARGE",
      credit?: false,
      flags: ["feeDeduction"],
      extra: ["payCharge", "chargeTransaction"]
    },
    17 => %{
      code: "savingsAccountTransactionType.overdraftInterest",
      value: "Overdraft Interest",
      enum: "OVERDRAFT_INTEREST",
      credit?: false,
      flags: ["overdraftInterest"],
      extra: ["overDraftInterestPosting", "incomeFromInterest"]
    }
  }

  @type_flags ~w(deposit dividendPayout withdrawal interestPosting feeDeduction initiateTransfer approveTransfer
                 withdrawTransfer rejectTransfer overdraftInterest writtenoff overdraftFee withholdTax escheat
                 amountHold amountRelease accrual)
  @extra_flags ~w(payCharge overDraftInterestPosting incomeFromInterest withdrawalFee chargeTransaction annualFee
                  depositOrWithdrawal)

  defp entry_type(%{credit?: nil}), do: nil
  defp entry_type(%{credit?: true}), do: "CREDIT"
  defp entry_type(%{credit?: false}), do: "DEBIT"

  @doc "The type of a transaction as Fineract shows it, `full?` with the entry type and what kind of charge it is."
  @spec type_json(integer, boolean) :: map
  def type_json(type, full?) do
    t = Map.fetch!(@types, type)

    base =
      @type_flags
      |> Map.new(&{&1, &1 in t.flags})
      |> Map.merge(%{"id" => type, "code" => t.code, "value" => t.value})

    if full? do
      @extra_flags
      |> Map.new(&{&1, &1 in t.extra})
      |> Map.merge(base)
      |> Map.merge(%{
        "debit" => t.credit? == false,
        "credit" => t.credit? == true,
        "entryType" => entry_type(t),
        "transactionTypeEnum" => t.enum
      })
    else
      base
    end
  end

  # the flags of a transaction in an account: the type's, and whether it is live
  defp interest_flags(type, reversed?) do
    %{
      "interestPosting" => type in [3, 17],
      "interestPostingAndNotReversed" => type == 3 and not reversed?,
      "overdraftInterestAndNotReversed" => type == 17 and not reversed?
    }
  end

  defp flags(_t, type, reversed?, reversal?) do
    t = Map.fetch!(@types, type)
    live? = not reversed? and not reversal?
    charge? = "chargeTransaction" in t.extra
    fee_flag? = type in [4, 5, 7]
    interest = interest_flags(type, reversed?)

    Map.merge(interest, %{
      "debit" => live? and t.credit? == false,
      "credit" => live? and t.credit? == true,
      "amountOnHold" => false,
      "payCharge" => type == 7,
      "waivePenaltyCharge" => false,
      "waiveFeeCharge" => false,
      "taxDetails" => [],
      "deposit" => type == 1,
      "accrual" => false,
      "withdrawal" => type == 2,
      "penaltyCharge" => false,
      "amountRelease" => false,
      "savingsAccountChargesPaid" => [],
      "manualTransaction" => false,
      "notReversed" => not reversed?,
      "waiveCharge" => type == 6,
      "reversalTransaction" => reversal?,
      "chargeTransaction" => charge?,
      "feeCharge" => false,
      "dividendPayoutAndNotReversed" => false,
      "withdrawalFeeAndNotReversed" => fee_flag? and not reversed?,
      "penaltyChargeAndNotReversed" => false,
      "withHoldTaxAndNotReversed" => false,
      "waiveFeeChargeAndNotReversed" => false,
      "waivePenaltyChargeAndNotReversed" => false,
      "annualFee" => type == 5,
      "feeChargeAndNotReversed" => false,
      "depositAndNotReversed" => type == 1 and not reversed?,
      "annualFeeAndNotReversed" => type == 5 and not reversed?,
      "chargeTransactionAndNotReversed" => charge? and not reversed?
    })
  end

  # a reversal enters the books the other way round
  defp entry(type, reversal?) do
    case Map.fetch!(@types, type).credit? do
      nil -> nil
      credit? -> if(credit? != reversal?, do: "CREDIT", else: "DEBIT")
    end
  end

  # --- writes ---------------------------------------------------------------------------------

  @transaction_commands %{
    "deposit" => "DEPOSIT",
    "withdrawal" => "WITHDRAWAL",
    "force-withdrawal" => "FORCE_WITHDRAWAL"
  }

  @transaction_command_names ["deposit", "withdrawal", "force-withdrawal", "holdAmount"]

  @doc "`POST /savingsaccounts/:id/transactions?command=...`"
  def command(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      command = String.trim(conn.query_params["command"] || "")

      cond do
        Map.has_key?(@transaction_commands, command) ->
          Write.execute(conn, @resource, Map.fetch!(@transaction_commands, command), id: id)

        command == "postInterestAsOn" ->
          Write.execute(conn, @resource, "POSTINTEREST", id: id)

        command == "holdAmount" ->
          not_supported(conn, command)

        true ->
          unknown_command(conn, conn.query_params["command"], @transaction_command_names)
      end
    end)
  end

  @adjust_commands %{
    "undo" => "UNDOTRANSACTION",
    "reverse" => "REVERSETRANSACTION",
    "modify" => "ADJUSTTRANSACTION"
  }
  @adjust_command_names ["undo", "modify", "releaseAmount", "reverse"]

  @doc "`POST /savingsaccounts/:id/transactions/:transaction_id?command=...`"
  def adjust(conn, raw_id, raw_tid) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, tid} <- Write.path_id(raw_tid) do
      command = String.trim(conn.query_params["command"] || "")

      cond do
        Map.has_key?(@adjust_commands, command) ->
          Write.execute(conn, @resource, Map.fetch!(@adjust_commands, command),
            id: id,
            subentity_id: tid
          )

        command == "releaseAmount" ->
          not_supported(conn, command)

        true ->
          unknown_command(conn, conn.query_params["command"], @adjust_command_names)
      end
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp unknown_command(conn, command, allowed),
    do:
      Errors.render(conn, %UnrecognizedQueryParameter{
        name: "command",
        value: command,
        allowed: allowed
      })

  defp not_supported(conn, command),
    do:
      Errors.render(conn, %DomainRuleViolation{
        code: "error.msg.savingsaccount.feature.not.supported.yet",
        message: "The savings account command #{command} is not supported yet by E-CoreBank",
        args: [command]
      })
end
