defmodule ECBLoans.Delinquency do
  @moduledoc """
  Delinquency ranges and buckets (`/v1/delinquency/ranges`, `/v1/delinquency/buckets`), after Fineract's
  `DelinquencyApiResource` and `DelinquencyWritePlatformServiceImpl`.

  A range names how late a loan is (`Early`, 1 to 3 days, ...); a bucket is a set of ranges that do not overlap, and a
  loan product points to a bucket. The loans of such a product are put in a range as they fall due (see
  `ECBLoans.Delinquency.Classify`). The tables are `m_delinquency_range`, `m_delinquency_bucket` and
  `m_delinquency_bucket_mappings`.

  Fineract's endpoints bind their body to a class first, so a parameter they do not know is ignored and a number given
  as text that is not one is refused as a bad number rather than as a validation problem. Buckets of the type
  `WORKING_CAPITAL` belong to loans E-CoreBank does not have and are refused.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Result

  alias ECBPlatform.Errors.{
    DataIntegrity,
    DomainRuleViolation,
    InvalidJsonData,
    InvalidNumber,
    ResourceNotFound
  }

  alias ECBPlatform.Errors.ServerError
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @bucket_types ~w(REGULAR WORKING_CAPITAL)
  @duplicated "error.msg.data.integrity.issue.entity.duplicated"
  @linked "error.msg.data.integrity.issue.entity.linked"

  # --- reads --------------------------------------------------------------------------------------

  @doc "Every range, oldest first."
  @spec ranges() :: [map]
  def ranges do
    from(r in "m_delinquency_range", as: :r, order_by: r.id) |> select_range() |> TenantRepo.all()
  end

  @doc "One range, or `nil`."
  @spec range(integer) :: map | nil
  def range(id) do
    from(r in "m_delinquency_range", as: :r, where: r.id == ^id)
    |> select_range()
    |> TenantRepo.one()
  end

  defp select_range(query) do
    select(query, [r: r], %{
      id: r.id,
      classification: r.classification,
      min: r.min_age_days,
      max: r.max_age_days,
      version: r.version,
      created_by: r.created_by,
      created_on: r.created_on_utc,
      modified_by: r.last_modified_by,
      modified_on: r.last_modified_on_utc
    })
  end

  @doc "Every bucket, oldest first, with its ranges."
  @spec buckets() :: [map]
  def buckets do
    from(b in "m_delinquency_bucket",
      order_by: b.id,
      select: %{id: b.id, name: b.name, type: b.bucket_type}
    )
    |> TenantRepo.all()
    |> Enum.map(&with_ranges/1)
  end

  @doc "One bucket with its ranges, or `nil`."
  @spec bucket(integer) :: map | nil
  def bucket(id) do
    from(b in "m_delinquency_bucket",
      where: b.id == ^id,
      select: %{id: b.id, name: b.name, type: b.bucket_type}
    )
    |> TenantRepo.one()
    |> then(&if(&1, do: with_ranges(&1)))
  end

  defp with_ranges(bucket), do: Map.put(bucket, :ranges, bucket_ranges(bucket.id))

  @doc "The ranges of bucket `bucket_id`, the earliest first."
  @spec bucket_ranges(integer) :: [map]
  def bucket_ranges(bucket_id) do
    from(m in "m_delinquency_bucket_mappings",
      join: r in "m_delinquency_range",
      as: :r,
      on: r.id == m.delinquency_range_id,
      where: m.delinquency_bucket_id == ^bucket_id,
      order_by: m.id
    )
    |> select_range()
    |> TenantRepo.all()
  end

  @doc "The error for a bucket that is not there."
  @spec bucket_not_found(integer) :: Exception.t()
  def bucket_not_found(id) do
    ResourceNotFound.new(
      "error.msg.delinquency.bucket.not.found",
      "Delinquency bucket with id `#{id}` is not found.",
      [id, []]
    )
  end

  # --- ranges: writes -----------------------------------------------------------------------------

  @doc "Creates a range."
  @spec create_range!(struct, Params.t()) :: Result.t()
  def create_range!(user, %Params{} = p) do
    {classification, min, max} = parse_range!(p)

    case TenantRepo.one(
           from(r in "m_delinquency_range",
             where: r.classification == ^classification,
             select: r.id
           )
         ) do
      nil ->
        if max != nil and min > max do
          raise DomainRuleViolation,
            code: "error.msg.loan.delinquency.age.days,invalid",
            message:
              "The age days values are invalid, the maximum age days can't be lower than minimum age days",
            args: [min, max]
        end

        {1, [%{id: id}]} =
          TenantRepo.insert_all(
            "m_delinquency_range",
            [
              audit(user, %{
                classification: classification,
                min_age_days: min,
                max_age_days: max
              })
            ],
            returning: [:id]
          )

        Result.new(resource_id: id)

      existing ->
        raise duplicated(existing)
    end
  end

  @doc "Changes a range."
  @spec update_range!(struct, integer, Params.t()) :: Result.t()
  def update_range!(user, id, %Params{} = p) do
    {classification, min, max} = parse_range!(p)
    range = range(id) || raise not_found_entity(id)

    changes =
      %{}
      |> put_if(
        not String.equivalent?(
          String.downcase(classification),
          String.downcase(range.classification)
        ),
        "classification",
        classification
      )
      |> put_if(min != range.min, "minimumAgeDays", min)

    # Fineract compares the new maximum with `equals` and so fails on a request without one
    if max == nil, do: raise(ServerError, message: "maximumAgeDays is null")
    changes = put_if(changes, max != range.max, "maximumAgeDays", max)

    if changes != %{} do
      if Map.has_key?(changes, "classification"),
        do: check_unique_classification!(classification, id)

      TenantRepo.update_all(from(r in "m_delinquency_range", where: r.id == ^id),
        set: [
          classification:
            if(changes["classification"], do: classification, else: range.classification),
          min_age_days: min,
          max_age_days: max,
          version: range.version + 1,
          last_modified_by: user.id,
          last_modified_on_utc: DateTime.utc_now()
        ]
      )
    end

    Result.new(resource_id: id, changes: if(changes != %{}, do: changes))
  end

  defp check_unique_classification!(classification, id) do
    if TenantRepo.exists?(
         from(r in "m_delinquency_range",
           where: r.classification == ^classification and r.id != ^id
         )
       ) do
      raise DataIntegrity,
        code: "error.msg.data.integrity.issue",
        message:
          "ERROR: duplicate key value violates unique constraint \"m_delinquency_range_classification_key\"\n  Detail: Key (classification)=(#{classification}) already exists.",
        args: []
    end
  end

  @doc "Removes a range that no loan was ever put in."
  @spec delete_range!(struct, integer) :: Result.t()
  def delete_range!(_user, id) do
    if TenantRepo.exists?(
         from(t in "m_loan_delinquency_tag_history", where: t.delinquency_range_id == ^id)
       ),
       do: raise(linked(id))

    try do
      TenantRepo.delete_all(from(r in "m_delinquency_range", where: r.id == ^id))
    rescue
      error in Postgrex.Error ->
        # a range that is in a bucket cannot go: Fineract shows the database's own words
        %{message: message, detail: detail} = error.postgres

        reraise %DataIntegrity{
                  code: "error.msg.data.integrity.issue",
                  message: "ERROR: #{message}\n  Detail: #{detail}",
                  args: []
                },
                __STACKTRACE__
    end

    Result.new(resource_id: id)
  end

  defp parse_range!(p) do
    classification = Params.string(p, "classification")
    locale = Params.string(p, "locale")

    errors =
      Validation.new("delinquencyrange.create")
      |> Validation.param("locale", locale)
      |> Validation.not_blank()

    min = age(p, "minimumAgeDays")
    max = age(p, "maximumAgeDays")

    errors
    |> Validation.param("classification", classification)
    |> Validation.not_blank()
    |> Validation.param("minimumAgeDays", min)
    |> Validation.not_null()
    |> Validation.greater_than_number(0)
    |> Validation.param("maximumAgeDays", max)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_number(0)
    |> Validation.raise_if_errors!()

    {classification, min, max}
  end

  # a whole number: a number, or text that is one (the body is bound to a class first); read in the request's locale
  defp age(p, key) do
    case number(p, key) do
      nil ->
        nil

      value ->
        Params.require_locale!(p, key)
        value
    end
  end

  defp number(p, key) do
    case Params.value(p, key) do
      nil -> nil
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value -> text_number!(key, value)
    end
  end

  defp text_number!(key, value) do
    case Integer.parse(String.trim(to_string(value))) do
      {n, ""} -> n
      _ -> raise InvalidNumber, parameter: key, value: to_string(value)
    end
  end

  # --- buckets: writes ----------------------------------------------------------------------------

  @doc "Creates a bucket."
  @spec create_bucket!(struct, Params.t()) :: Result.t()
  def create_bucket!(user, %Params{} = p) do
    {name, type, range_ids} = parse_bucket!(p)

    case TenantRepo.one(from(b in "m_delinquency_bucket", where: b.name == ^name, select: b.id)) do
      nil ->
        {1, [%{id: id}]} =
          TenantRepo.insert_all(
            "m_delinquency_bucket",
            [audit(user, %{name: name, bucket_type: type || "REGULAR"})],
            returning: [:id]
          )

        set_mappings!(user, id, range_ids)
        Result.new(resource_id: id)

      existing ->
        raise duplicated(existing)
    end
  end

  @doc "Changes a bucket."
  @spec update_bucket!(struct, integer, Params.t()) :: Result.t()
  def update_bucket!(user, id, %Params{} = p) do
    {name, type, range_ids} = parse_bucket!(p)
    bucket = bucket(id) || raise not_found_entity(id)

    changes = %{} |> rename(name, bucket) |> retype(type, bucket)

    if changes != %{} do
      TenantRepo.update_all(from(b in "m_delinquency_bucket", where: b.id == ^id),
        set: [
          name: if(changes["name"], do: name, else: bucket.name),
          bucket_type: type || bucket.type,
          last_modified_by: user.id,
          last_modified_on_utc: DateTime.utc_now()
        ]
      )
    end

    set_mappings!(user, id, range_ids)
    Result.new(resource_id: id, changes: if(changes != %{}, do: changes))
  end

  # a name that differs (but for its case) must not be taken
  defp rename(changes, name, bucket) do
    if String.downcase(name) == String.downcase(bucket.name) do
      changes
    else
      taken =
        TenantRepo.one(from(b in "m_delinquency_bucket", where: b.name == ^name, select: b.id))

      if taken, do: raise(duplicated(taken))
      Map.put(changes, "name", name)
    end
  end

  # a bucket a product uses keeps its type
  defp retype(changes, type, bucket) do
    if type == nil or type == bucket.type do
      changes
    else
      if in_use?(bucket.id), do: raise(linked(bucket.id))
      Map.put(changes, "bucketType", type)
    end
  end

  @doc "Removes a bucket no product uses."
  @spec delete_bucket!(struct, integer) :: Result.t()
  def delete_bucket!(_user, id) do
    if bucket(id) == nil do
      raise ResourceNotFound.new(
              "error.msg.delinquency.bucket.id.not.exist",
              "Delinquency bucket with id `#{id}` does not exist.",
              [id]
            )
    end

    if in_use?(id), do: raise(linked(id))

    TenantRepo.delete_all(
      from(m in "m_delinquency_bucket_mappings", where: m.delinquency_bucket_id == ^id)
    )

    TenantRepo.delete_all(from(b in "m_delinquency_bucket", where: b.id == ^id))
    Result.new(resource_id: id)
  end

  defp in_use?(id),
    do: TenantRepo.exists?(from(p in "m_product_loan", where: p.delinquency_bucket_id == ^id))

  defp parse_bucket!(p) do
    name = Params.string(p, "name")
    type = Params.string(p, "bucketType")
    ranges = range_ids(p)

    v =
      Validation.new("delinquencyBucket.create")
      |> Validation.param("name", name)
      |> Validation.not_blank()
      |> Validation.param("bucketType", type)
      |> Validation.ignore_if_null()
      |> Validation.one_of(@bucket_types)

    # Fineract stops at the problems with the name and the type before it looks at the ranges
    if Validation.errors?(v), do: Validation.raise_if_errors!(v)

    v
    |> Validation.param("ranges", ranges)
    |> Validation.not_null()
    |> Validation.array_not_empty()
    |> Validation.raise_if_errors!()

    if type == "WORKING_CAPITAL" do
      # a bucket for working capital loans needs the minimum payment period and rule
      Validation.new("delinquencyBucket.create")
      |> Validation.param(
        "minimumPaymentPeriodAndRule",
        Params.value(p, "minimumPaymentPeriodAndRule")
      )
      |> Validation.not_null()
      |> Validation.raise_if_errors!()

      raise DomainRuleViolation,
        code: "error.msg.delinquency.feature.not.supported.yet",
        message:
          "A delinquency bucket for working capital loans is not supported yet by E-CoreBank",
        args: ["bucketType"]
    end

    {name, type, ranges}
  end

  defp range_ids(p) do
    case Params.value(p, "ranges") do
      nil -> nil
      list when is_list(list) -> Enum.map(list, &range_id!/1)
      _other -> raise InvalidJsonData
    end
  end

  defp range_id!(value) when is_integer(value), do: value
  defp range_id!(value) when is_float(value), do: trunc(value)

  defp range_id!(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {n, ""} -> n
      _ -> raise InvalidNumber, parameter: nil, value: to_string(value)
    end
  end

  # the ranges of a bucket are the ones asked for that exist; they may not overlap
  defp set_mappings!(user, bucket_id, range_ids) do
    ranges =
      from(r in "m_delinquency_range",
        as: :r,
        where: r.id in ^Enum.uniq(range_ids),
        order_by: r.id
      )
      |> select_range()
      |> TenantRepo.all()

    check_overlaps!(ranges)

    TenantRepo.delete_all(
      from(m in "m_delinquency_bucket_mappings", where: m.delinquency_bucket_id == ^bucket_id)
    )

    unless ranges == [] do
      TenantRepo.insert_all(
        "m_delinquency_bucket_mappings",
        Enum.map(
          ranges,
          &audit(user, %{delinquency_bucket_id: bucket_id, delinquency_range_id: &1.id})
        )
      )
    end

    :ok
  end

  defp check_overlaps!(ranges) do
    ranges
    |> Enum.sort_by(& &1.min)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      if overlapped?(a, b) do
        raise DomainRuleViolation,
          code: "error.msg.loan.delinquency.bucket.ages.overlaped",
          message: "The delinquency ranges age days values are overlaped",
          args: [entity(a), entity(b)]
      end
    end)
  end

  # Fineract's test: the last range (no maximum) is compared by its minimum, and an earlier one without a maximum
  # fails the comparison altogether
  defp overlapped?(a, %{max: nil} = b),
    do: max(a.min, b.min) <= min(a.max || raise(ServerError), b.min)

  defp overlapped?(a, b), do: max(a.min, b.min) <= min(a.max || raise(ServerError), b.max)

  @doc """
  A range as Fineract's entity serialises it: the message of a failed bucket shows it with `new`, the answer to an
  assignment with `isNew`.
  """
  @spec entity(map, String.t()) :: map
  def entity(r, new_key \\ "new") do
    %{
      "id" => r.id,
      "createdBy" => r.created_by,
      "createdDate" => iso(r.created_on),
      "lastModifiedBy" => r.modified_by,
      "lastModifiedDate" => iso(r.modified_on),
      "classification" => r.classification,
      "minimumAgeDays" => r.min,
      "version" => r.version
    }
    |> Map.put(new_key, false)
    |> then(&if(r.max, do: Map.put(&1, "maximumAgeDays", r.max), else: &1))
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"

  # --- shared ------------------------------------------------------------------------------------

  defp audit(user, row) do
    now = DateTime.utc_now()

    Map.merge(row, %{
      created_by: user.id,
      created_on_utc: now,
      version: 1,
      last_modified_by: user.id,
      last_modified_on_utc: now
    })
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp duplicated(existing_id),
    do: %DataIntegrity{
      code: @duplicated,
      message: "Data integrity issue with resource: #{existing_id}",
      args: []
    }

  defp linked(id),
    do: %DataIntegrity{
      code: @linked,
      message: "Data integrity issue with resource: #{id}",
      args: []
    }

  defp not_found_entity(id),
    do: %DataIntegrity{
      code: "error.msg.persistence.error",
      message: "Could not find Entity for id: #{id}",
      args: []
    }
end
