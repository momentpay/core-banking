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
    credit_type? = t.transaction_type_enum == 1
    reversed? = t.is_reversed == true
    reversal? = t.is_reversal == true

    base = %{
      "id" => t.id,
      "transactionType" => type_json(t.transaction_type_enum, full?),
      "entryType" => if(credit_type? != reversal?, do: "CREDIT", else: "DEBIT"),
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
      "isManualTransaction" => t.is_manual == true,
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
        |> Map.merge(flags(t, credit_type?, reversed?, reversal?)),
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

  @type_names %{
    1 => {"savingsAccountTransactionType.deposit", "Deposit", "DEPOSIT", "deposit"},
    2 => {"savingsAccountTransactionType.withdrawal", "Withdrawal", "WITHDRAWAL", "withdrawal"}
  }

  @type_flags ~w(deposit dividendPayout withdrawal interestPosting feeDeduction initiateTransfer approveTransfer
                 withdrawTransfer rejectTransfer overdraftInterest writtenoff overdraftFee withholdTax escheat
                 amountHold amountRelease accrual)

  defp type_json(type, full?) do
    {code, value, enum, kind} = Map.fetch!(@type_names, type)

    base =
      @type_flags
      |> Map.new(&{&1, &1 == kind})
      |> Map.merge(%{"id" => type, "code" => code, "value" => value})

    if full? do
      Map.merge(base, %{
        "debit" => kind == "withdrawal",
        "credit" => kind == "deposit",
        "payCharge" => false,
        "overDraftInterestPosting" => false,
        "incomeFromInterest" => false,
        "entryType" => if(kind == "deposit", do: "CREDIT", else: "DEBIT"),
        "withdrawalFee" => false,
        "chargeTransaction" => false,
        "annualFee" => false,
        "depositOrWithdrawal" => true,
        "transactionTypeEnum" => enum
      })
    else
      base
    end
  end

  defp flags(t, credit_type?, reversed?, reversal?) do
    live? = not reversed? and not reversal?

    %{
      "debit" => live? and not credit_type?,
      "credit" => live? and credit_type?,
      "amountOnHold" => false,
      "payCharge" => false,
      "waivePenaltyCharge" => false,
      "waiveFeeCharge" => false,
      "taxDetails" => [],
      "deposit" => credit_type?,
      "accrual" => false,
      "interestPosting" => false,
      "withdrawal" => not credit_type?,
      "penaltyCharge" => false,
      "amountRelease" => false,
      "savingsAccountChargesPaid" => [],
      "interestPostingAndNotReversed" => false,
      "overdraftInterestAndNotReversed" => false,
      "manualTransaction" => t.is_manual == true,
      "notReversed" => not reversed?,
      "waiveCharge" => false,
      "reversalTransaction" => reversal?,
      "chargeTransaction" => false,
      "feeCharge" => false,
      "dividendPayoutAndNotReversed" => false,
      "withdrawalFeeAndNotReversed" => false,
      "penaltyChargeAndNotReversed" => false,
      "withHoldTaxAndNotReversed" => false,
      "waiveFeeChargeAndNotReversed" => false,
      "waivePenaltyChargeAndNotReversed" => false,
      "annualFee" => false,
      "feeChargeAndNotReversed" => false,
      "depositAndNotReversed" => credit_type? and not reversed?,
      "annualFeeAndNotReversed" => false,
      "chargeTransactionAndNotReversed" => false
    }
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
