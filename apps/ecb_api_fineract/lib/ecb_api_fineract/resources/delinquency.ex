defmodule ECBApiFineract.Resources.Delinquency do
  @moduledoc """
  `/v1/delinquency`: the delinquency ranges and buckets, and the delinquency tags and actions of a loan
  (`/v1/loans/{id}/delinquencytags`, `/v1/loans/{id}/delinquency-actions`), after Fineract's
  `DelinquencyApiResource` and `LoansApiResource`.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBLoans.Delinquency
  alias ECBLoans.Delinquency.{Actions, Classify}

  @bucket "DELINQUENCY_BUCKET"
  @range "DELINQUENCY_RANGE"

  # --- ranges --------------------------------------------------------------------------------------

  @doc "`GET /delinquency/ranges`"
  def ranges(conn),
    do: Read.respond(conn, @bucket, fn -> Enum.map(Delinquency.ranges(), &range/1) end)

  @doc "`GET /delinquency/ranges/:id`"
  def range_show(conn, raw_id) do
    Read.respond(conn, @bucket, fn ->
      with {:ok, id} <- Write.path_id(raw_id), {:ok, r} <- found_range(id), do: range(r)
    end)
  end

  # Fineract's lazy reference to a range that is not there fails its read with a plain 500
  defp found_range(id) do
    case Delinquency.range(id) do
      nil -> {:error, %ECBPlatform.Errors.ServerError{message: "range #{id} is not there"}}
      r -> {:ok, r}
    end
  end

  @doc "`POST /delinquency/ranges`"
  def range_create(conn), do: Write.execute(conn, @range, "CREATE")

  @doc "`PUT /delinquency/ranges/:id`"
  def range_update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @range, "UPDATE", id: &1))

  @doc "`DELETE /delinquency/ranges/:id`"
  def range_delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @range, "DELETE", id: &1))

  @doc "A range as the API shows it (Fineract leaves out a maximum that is not set)."
  @spec range(map) :: map
  def range(r) do
    base = %{"id" => r.id, "classification" => r.classification, "minimumAgeDays" => r.min}
    if r.max, do: Map.put(base, "maximumAgeDays", r.max), else: base
  end

  # --- buckets -------------------------------------------------------------------------------------

  @bucket_types [
    %{"id" => "REGULAR", "code" => "bucketType.regular", "value" => "Reqular Loan Product"},
    %{
      "id" => "WORKING_CAPITAL",
      "code" => "bucketType.workingCapital",
      "value" => "Working Capital Loan Product"
    }
  ]

  @frequency_types [
    %{"id" => "DAYS", "code" => "delinquencyFrequencyType.days", "value" => "Days frequency"},
    %{"id" => "WEEKS", "code" => "delinquencyFrequencyType.weeks", "value" => "Week frequency"},
    %{
      "id" => "MONTHS",
      "code" => "delinquencyFrequencyType.months",
      "value" => "Month frequency"
    },
    %{"id" => "YEARS", "code" => "delinquencyFrequencyType.years", "value" => "Year frequency"}
  ]

  @minimum_payment_types [
    %{
      "id" => "PERCENTAGE",
      "code" => "delinquencyMinimumPayment.percentage",
      "value" => "Percentage payment type"
    },
    %{"id" => "FLAT", "code" => "delinquencyMinimumPayment.flat", "value" => "Flat payment type"}
  ]

  @doc "`GET /delinquency/buckets/template`"
  def bucket_template(conn) do
    Read.respond(conn, @bucket, fn ->
      %{
        "rangesOptions" => Enum.map(Delinquency.ranges(), &range/1),
        "bucketTypeOptions" => @bucket_types,
        "frequencyTypeOptions" => @frequency_types,
        "minimumPaymentOptions" => @minimum_payment_types
      }
    end)
  end

  @doc "`GET /delinquency/buckets`"
  def buckets(conn),
    do: Read.respond(conn, @bucket, fn -> Enum.map(Delinquency.buckets(), &bucket/1) end)

  @doc "`GET /delinquency/buckets/:id`"
  def bucket_show(conn, raw_id) do
    Read.respond(conn, @bucket, fn ->
      with {:ok, id} <- Write.path_id(raw_id), {:ok, b} <- found_bucket(id), do: bucket(b)
    end)
  end

  defp found_bucket(id) do
    case Delinquency.bucket(id) do
      nil -> {:error, Delinquency.bucket_not_found(id)}
      b -> {:ok, b}
    end
  end

  @doc "`POST /delinquency/buckets`"
  def bucket_create(conn), do: Write.execute(conn, @bucket, "CREATE")

  @doc "`PUT /delinquency/buckets/:id`"
  def bucket_update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @bucket, "UPDATE", id: &1))

  @doc "`DELETE /delinquency/buckets/:id`"
  def bucket_delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @bucket, "DELETE", id: &1))

  @doc "A bucket as the API shows it."
  @spec bucket(map) :: map
  def bucket(b) do
    %{
      "id" => b.id,
      "name" => b.name,
      "ranges" => Enum.map(b.ranges, &range/1),
      "bucketType" => Enum.find(@bucket_types, &(&1["id"] == b.type))
    }
  end

  @doc "A bucket as a loan product shows it: the type is its name and the ranges are left out."
  @spec product_bucket(map) :: map
  def product_bucket(b),
    do: %{"id" => b.id, "name" => b.name, "ranges" => [], "bucketType" => b.type}

  @doc "A bucket as the options of a product show it: the type is its name."
  @spec bucket_option(map) :: map
  def bucket_option(b),
    do: %{
      "id" => b.id,
      "name" => b.name,
      "ranges" => Enum.map(b.ranges, &range/1),
      "bucketType" => b.type
    }

  # --- a loan's tags and actions -------------------------------------------------------------------

  @doc "`GET /loans/:id/delinquencytags`"
  def tags(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, "DELINQUENCY_TAGS", fn ->
        id
        |> Classify.history()
        |> Enum.map(&tag(&1, id))
      end)
    end)
  end

  defp tag(t, loan_id) do
    base = %{
      "id" => t.id,
      "loanId" => loan_id,
      "delinquencyRange" => range(Delinquency.range(t.range_id)),
      "addedOnDate" => t.added
    }

    if t.lifted, do: Map.put(base, "liftedOnDate", t.lifted), else: base
  end

  @doc "`GET /loans/:id/delinquency-actions`"
  def actions(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, "LOAN", fn -> id |> Actions.list() |> Enum.map(&action/1) end)
    end)
  end

  defp action(a) do
    base = %{
      "id" => a.id,
      "action" => a.action,
      "startDate" => a.start,
      "createdById" => a.created_by,
      "createdOn" => a.created_on,
      "updatedById" => a.updated_by,
      "lastModifiedOn" => a.updated_on
    }

    if a.end, do: Map.put(base, "endDate", a.end), else: base
  end

  @doc "`POST /loans/:id/delinquency-actions`"
  def create_action(conn, raw_id) do
    Write.with_path_id(conn, raw_id, &Write.execute(conn, "DELINQUENCY_ACTION", "CREATE", id: &1))
  end

  @doc "The range a loan is in, for the loan's own read; `nil` when it is in none."
  @spec loan_range(integer) :: map | nil
  def loan_range(loan_id) do
    case Classify.current_range(loan_id) do
      nil -> nil
      r -> range(r)
    end
  end
end
