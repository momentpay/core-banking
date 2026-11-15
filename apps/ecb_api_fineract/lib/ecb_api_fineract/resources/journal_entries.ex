defmodule ECBApiFineract.Resources.JournalEntries do
  @moduledoc """
  `/v1/journalentries`: the entries posted to the ledger, one posting, the reversal of a posting and the
  running balances. Reading needs `READ_JOURNALENTRY`.

  List filters: `officeId`, `glAccountId`, `manualEntriesOnly`, `fromDate` and `toDate` (with
  `dateFormat` and `locale`), `submittedOnDateFrom` and `submittedOnDateTo`, `transactionId`,
  `entityType`, `loanId`, `savingsId`, `offset`, `limit`, `orderBy` and `sortOrder`.
  `runningBalance=true` adds the balances and `transactionDetails=true` the payment details. `fields`
  keeps only the named fields, in every level of the entry, as Fineract's serialiser does.

  A value in the query that is not the number a filter needs is the web container's plain 404, as
  Fineract answers it.

  Posting is `POST /journalentries`; `?command=updateRunningBalance` brings the balances up to date; a
  posting is reversed with `POST /journalentries/<transactionId>?command=reverse`.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.{GLAccounts, Read, Write}
  alias ECBLedger.Journal
  alias ECBLedger.Journal.OpeningBalance
  alias ECBPlatform.Errors.{PlatformApiDataValidation, UnrecognizedQueryParameter}
  alias ECBPlatform.Params

  @provisioning 3

  @doc "`GET /journalentries`"
  def index(conn) do
    query = conn.query_params
    options = options(query)

    Read.respond(conn, "JOURNALENTRY", fn ->
      with {:ok, filters} <- filters(query),
           {:ok, %{total: total, items: items}} <- list(filters) do
        %{
          "totalFilteredRecords" => total,
          "pageItems" => Enum.map(items, &(&1 |> serialize(options) |> only_fields(query)))
        }
      end
    end)
  end

  @doc "`GET /journalentries/:id`"
  def show(conn, raw_id) do
    query = conn.query_params
    options = options(query)

    Read.respond(conn, "JOURNALENTRY", fn ->
      with {:ok, id} <- Write.path_id(raw_id),
           {:ok, entry} <- Journal.get(id),
           do: entry |> serialize(options) |> only_fields(query)
    end)
  end

  @doc "`GET /journalentries/openingbalance?officeId=&currencyCode=`"
  def opening_balance(conn) do
    query = conn.query_params

    Read.respond(conn, "JOURNALENTRY", fn ->
      with {:ok, office_id} <- long(query, "officeId") do
        office_id
        |> OpeningBalance.retrieve!(query["currencyCode"])
        |> opening_balances()
      end
    end)
  rescue
    error in [ECBPlatform.Errors.ServerError, ECBOrg.Errors.OfficeNotFound] ->
      Errors.render(conn, error)
  end

  @doc "`GET /journalentries/provisioning?entryId=`: the entries a provisioning run posted. Any signed-in user."
  def provisioning(conn) do
    query = conn.query_params

    with {:ok, entry_id} <- long(query, "entryId"),
         {:ok, offset} <- long(query, "offset"),
         {:ok, limit} <- long(query, "limit") do
      %{total: total, items: items} =
        Journal.list(
          transaction_id: "P#{entry_id}",
          entity_type: @provisioning,
          offset: offset,
          limit: limit
        )

      Response.json(conn, 200, %{
        "totalFilteredRecords" => total,
        "pageItems" => Enum.map(items, &(&1 |> serialize(options(%{})) |> only_fields(query)))
      })
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "`POST /journalentries`: a posting, or with `?command=` one of the commands that share the path."
  def create(conn) do
    case command(conn) do
      "updaterunningbalance" -> Write.execute(conn, "JOURNALENTRY", "UPDATERUNNINGBALANCE")
      "defineopeningbalance" -> Write.execute(conn, "JOURNALENTRY", "DEFINEOPENINGBALANCE")
      _ -> Write.execute(conn, "JOURNALENTRY", "CREATE")
    end
  end

  @doc "`POST /journalentries/:transaction_id?command=reverse`"
  def reverse(conn, transaction_id) do
    case command(conn) do
      "reverse" ->
        Write.execute(conn, "JOURNALENTRY", "REVERSE", transaction_id: transaction_id)

      _ ->
        Errors.render(conn, %UnrecognizedQueryParameter{
          name: "command",
          value: conn.query_params["command"]
        })
    end
  end

  defp command(conn) do
    case conn.query_params["command"] do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  # --- the query ------------------------------------------------------------------------------

  defp options(query),
    do: %{
      running_balance: flag(query["runningBalance"]),
      details: flag(query["transactionDetails"])
    }

  defp flag(value), do: is_binary(value) and String.downcase(value) == "true"

  defp filters(query) do
    with {:ok, office_id} <- long(query, "officeId"),
         {:ok, account_id} <- long(query, "glAccountId"),
         {:ok, entity_type} <- long(query, "entityType"),
         {:ok, offset} <- long(query, "offset"),
         {:ok, limit} <- long(query, "limit"),
         {:ok, loan_id} <- long(query, "loanId"),
         {:ok, savings_id} <- long(query, "savingsId") do
      dates = Params.parse!(Jason.encode!(with_locale(query)))

      {:ok,
       [
         office_id: office_id,
         gl_account_id: account_id,
         entity_type: entity_type,
         manual_only: manual_only(query["manualEntriesOnly"]),
         from_date: date(dates, "fromDate"),
         to_date: date(dates, "toDate"),
         submitted_from: date(dates, "submittedOnDateFrom"),
         submitted_to: date(dates, "submittedOnDateTo"),
         transaction_id: query["transactionId"],
         loan_id: loan_id,
         savings_id: savings_id,
         offset: offset,
         limit: limit,
         order_by: query["orderBy"],
         sort_order: query["sortOrder"]
       ]}
    end
  end

  # A number the web container could not read: it never reaches the application.
  defp long(query, name) do
    case query[name] do
      value when value in [nil, ""] ->
        {:ok, nil}

      value ->
        case Integer.parse(value) do
          {number, ""} -> {:ok, number}
          _ -> {:error, %Errors.PathNotFound{}}
        end
    end
  end

  # `manualEntriesOnly` is a Boolean: anything but `true` is false, and absent is something else again
  defp manual_only(nil), do: nil
  defp manual_only(value), do: String.downcase(value) == "true"

  # A date in the query needs a locale: an absent one is reported as blank, as Fineract does.
  defp with_locale(query) do
    if Enum.any?(
         ~w(fromDate toDate submittedOnDateFrom submittedOnDateTo),
         &Map.has_key?(query, &1)
       ),
       do: Map.put_new(query, "locale", ""),
       else: query
  end

  # Fineract reads a date in the query with Java's strict year letter, which it shows in its complaint.
  defp date(params, key) do
    Params.date(params, key)
  rescue
    error in PlatformApiDataValidation ->
      reraise %{error | errors: Enum.map(error.errors, &strict_year/1)}, __STACKTRACE__
  end

  defp strict_year(%{code: "validation.msg.invalid.dateFormat.format"} = error) do
    %{
      error
      | developer_message: String.replace(error.developer_message, "yyyy", "uuuu"),
        default_message: String.replace(error.default_message, "yyyy", "uuuu"),
        args:
          Enum.map(
            error.args,
            &if(is_binary(&1), do: String.replace(&1, "yyyy", "uuuu"), else: &1)
          )
    }
  end

  defp strict_year(error), do: error

  # an `orderBy` that is not a column is a server error in Fineract
  defp list(filters) do
    {:ok, Journal.list(filters)}
  rescue
    error in ECBLedger.Errors.InvalidOrderBy -> {:error, error}
  end

  # The accounts grouped by type, each as the entry that set its opening balance, or, when it has none,
  # as the bare account. (Fineract's key for the liabilities is spelled `liabity`.)
  defp opening_balances(opening) do
    groups = Enum.group_by(opening.rows, &row_type/1, &row/1)

    %{
      "officeId" => opening.office_id,
      "officeName" => opening.office_name,
      "transactionDate" => opening.date,
      "contraAccount" => GLAccounts.account_json(opening.contra),
      "assetAccountOpeningBalances" => Map.get(groups, 1, []),
      "liabityAccountOpeningBalances" => Map.get(groups, 2, []),
      "incomeAccountOpeningBalances" => Map.get(groups, 4, []),
      "equityAccountOpeningBalances" => Map.get(groups, 3, []),
      "expenseAccountOpeningBalances" => Map.get(groups, 5, [])
    }
  end

  defp row_type({:account, account}), do: account.type_id
  defp row_type({:entry, entry}), do: entry.classification

  defp row({:entry, entry}), do: serialize(entry, options(%{}))

  defp row({:account, account}) do
    %{
      "glAccountName" => account.name,
      "glAccountId" => account.id,
      "glAccountCode" => account.gl_code,
      "glAccountType" => Read.option(ECBLedger.GLAccounts.type_option(account.type_id))
    }
  end

  # --- serialising ----------------------------------------------------------------------------

  defp serialize(e, options) do
    %{
      "id" => e.id,
      "officeId" => e.office_id,
      "officeName" => e.office_name,
      "glAccountName" => e.gl_account_name,
      "glAccountId" => e.gl_account_id,
      "glAccountCode" => e.gl_code,
      "glAccountType" => Read.option(ECBLedger.GLAccounts.type_option(e.classification)),
      "transactionDate" => e.transaction_date,
      "entryType" => Read.option(Journal.entry_type(e.type)),
      "amount" => e.amount,
      "currency" => currency(e.currency),
      "transactionId" => e.transaction_id,
      "manualEntry" => e.manual_entry,
      "entityType" => e.entity_type && Read.option(e.entity_type),
      "entityId" => e.entity_id,
      "createdByUserId" => e.created_by_user_id,
      "createdDate" => e.submitted_on_date,
      "createdByUserName" => e.created_by_username,
      "comments" => e.comments,
      "reversed" => e.reversed,
      "referenceNumber" => e.reference_number,
      "submittedOnDate" => e.submitted_on_date
    }
    |> with_running_balance(e, options.running_balance)
    |> with_details(e, options.details)
  end

  defp currency(c) do
    %{
      "code" => c.code,
      "name" => c.name,
      "decimalPlaces" => c.decimal_places,
      "inMultiplesOf" => c.multiples_of,
      "displaySymbol" => if(c.display_symbol in [nil, ""], do: nil, else: c.display_symbol),
      "nameCode" => c.name_code,
      "displayLabel" => ECBOrg.Currencies.display_label(c.name, c.code, c.display_symbol)
    }
  end

  defp with_running_balance(body, e, true),
    do:
      Map.merge(body, %{
        "officeRunningBalance" => e.office_running_balance,
        "organizationRunningBalance" => e.organization_running_balance,
        "runningBalanceComputed" => e.running_balance_computed
      })

  defp with_running_balance(body, _e, false), do: body

  # Fineract reuses the entry's own id as the id of the payment detail it shows.
  defp with_details(body, e, true),
    do: Map.put(body, "transactionDetails", details(e))

  defp with_details(body, _e, false), do: body

  defp details(%{payment: nil}), do: %{}

  defp details(%{payment: p} = e) do
    %{
      "paymentDetails" => %{
        "id" => e.id,
        "paymentType" => %{"id" => p.type_id, "name" => p.type_name},
        "accountNumber" => p.account_number,
        "checkNumber" => p.check_number,
        "routingCode" => p.routing_code,
        "receiptNumber" => p.receipt_number,
        "bankNumber" => p.bank_number
      }
    }
  end

  # The fields Fineract lets `fields` choose between. A name in this list that was not asked for is left
  # out wherever it appears, so a nested `entryType` loses its `id` unless `id` is asked for too; names
  # outside the list (`code`, `value`, the running balances) are never filtered.
  @choosable ~w(id officeId officeName glAccountName glAccountId glAccountCode glAccountType
                transactionDate entryType amount transactionId manualEntry entityType entityId
                createdByUserId createdDate submittedOnDate createdByUserName comments reversed
                referenceNumber currency transactionDetails)

  defp only_fields(body, query) do
    case query["fields"] do
      fields when is_binary(fields) and fields != "" ->
        wanted = fields |> String.split(",") |> Enum.map(&String.trim/1)
        drop = MapSet.new(@choosable -- wanted)
        filter(body, drop)

      _ ->
        body
    end
  end

  defp filter(%{__struct__: _} = struct, _drop), do: struct

  defp filter(map, drop) when is_map(map),
    do: for({k, v} <- map, not MapSet.member?(drop, k), into: %{}, do: {k, filter(v, drop)})

  defp filter(list, drop) when is_list(list), do: Enum.map(list, &filter(&1, drop))
  defp filter(other, _drop), do: other
end
