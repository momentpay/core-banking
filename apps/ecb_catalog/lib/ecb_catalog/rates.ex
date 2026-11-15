defmodule ECBCatalog.Rates do
  @moduledoc """
  Rates (`m_rate`): named percentages a loan product can carry (a risk or pricing rate, say), following
  Fineract's `RateReadServiceImpl`, `Rate` and `RateWriteServiceImpl`.

  A rate applies to a kind of product, which cannot be changed. Only loans are known, so any other value
  is stored as "invalid" and shown that way. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @fields ~w(name percentage productApply active locale)
  @loan 1

  @doc "Every rate, by id."
  @spec list() :: [map]
  def list, do: base() |> order_by([r], r.id) |> TenantRepo.all() |> Enum.map(&finish/1)

  @doc "One rate, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([r], r.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  # --- write ----------------------------------------------------------------------------------

  @doc "Creates the rate `params` describe."
  @spec create!(Params.t(), map) :: Result.t()
  def create!(%Params{} = params, user) do
    p = Params.typed(params, @fields)
    if Params.exists?(p, "active"), do: Params.strict_boolean(p, "active")

    name = Params.string(p, "name")
    percentage = Params.decimal(p, "percentage")
    apply_text = product_apply_text(p)

    Validation.new("name")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.max_length(250)
    |> Validation.param("percentage", percentage)
    |> Validation.not_blank()
    |> Validation.param("productApply", apply_text)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    now = now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_rate",
        [
          %{
            name: name,
            percentage: percentage,
            product_apply: applies_to(apply_text),
            active: Params.strict_boolean(p, "active") == true,
            created_date: now,
            createdby_id: user.id,
            lastmodifiedby_id: user.id,
            lastmodified_date: now
          }
        ],
        returning: [:id]
      )

    Result.new(resource_id: id)
  end

  @doc "Changes rate `id`: its name, percentage or whether it is active."
  @spec update!(integer, Params.t(), map) :: Result.t()
  def update!(id, %Params{} = params, user) do
    p = Params.typed(params, @fields)
    if Params.exists?(p, "active"), do: Params.strict_boolean(p, "active")

    rate = fetch!(id)
    {changes, set} = changes(p, rate)
    validate_update!(p)

    unless set == [] do
      TenantRepo.update_all(from(r in "m_rate", where: r.id == ^id),
        set: set ++ [lastmodifiedby_id: user.id, lastmodified_date: now()]
      )
    end

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  defp fetch!(id) do
    case get(id) do
      {:ok, rate} -> rate
      {:error, error} -> raise error
    end
  end

  # What the request changes. What a rate applies to is refused, not changed.
  defp changes(p, rate) do
    if Params.exists?(p, "productApply") and Params.long(p, "productApply") != rate.applies_to do
      raise DomainRuleViolation,
        code: "error.msg.charge.update.of.rate.applies.to.is.not.supported",
        message: "Update of Rate applies to is not supported",
        args: []
    end

    {%{}, []}
    |> text(p, "name", rate.name, :name)
    |> number(p, "percentage", rate.percentage, :percentage)
    |> flag(p, "active", rate.active, :active)
  end

  defp text({changes, set}, p, key, existing, column) do
    if Params.changed_string?(p, key, existing) do
      value = Params.command_string(p, key)
      {Map.put(changes, key, value), set ++ [{column, value}]}
    else
      {changes, set}
    end
  end

  defp number({changes, set}, p, key, existing, column) do
    if Params.changed_decimal?(p, key, existing) do
      value = Params.decimal(p, key)
      {Map.put(changes, key, value), set ++ [{column, value}]}
    else
      {changes, set}
    end
  end

  defp flag({changes, set}, p, key, existing, column) do
    if Params.changed_boolean?(p, key, existing) do
      value = Params.strict_boolean(p, key) == true
      {Map.put(changes, key, value), set ++ [{column, value}]}
    else
      {changes, set}
    end
  end

  defp validate_update!(p) do
    v = Validation.new("rate")

    v =
      if Params.exists?(p, "name"),
        do:
          v
          |> Validation.param("name", Params.string(p, "name"))
          |> Validation.not_blank()
          |> Validation.max_length(250),
        else: v

    v =
      if Params.exists?(p, "percentage"),
        do:
          v
          |> Validation.param("percentage", Params.decimal(p, "percentage"))
          |> Validation.not_blank(),
        else: v

    v =
      if Params.exists?(p, "productApply"),
        do:
          v |> Validation.param("productApply", product_apply_text(p)) |> Validation.not_blank(),
        else: v

    Validation.raise_if_errors!(v)
  end

  # What a rate applies to arrives as a number and is read as text, which needs the request's locale.
  defp product_apply_text(p) do
    value = Params.value(p, "productApply")

    if is_number(value) and is_nil(Params.locale(p)) do
      raise ECBPlatform.Errors.PlatformApiDataValidation,
        errors: [
          ECBPlatform.Errors.parameter_error(
            "validation.msg.missing.locale.parameter",
            "The parameter `productApply` requires a `locale` parameter to be passed with it.",
            "productApply"
          )
        ]
    end

    Params.string(p, "productApply")
  end

  defp applies_to(text) do
    case text && Integer.parse(String.trim(text)) do
      {@loan, ""} -> @loan
      _ -> 0
    end
  end

  # --- internals ------------------------------------------------------------------------------

  defp base do
    from(r in "m_rate",
      select: %{
        id: r.id,
        name: r.name,
        percentage: r.percentage,
        applies_to: r.product_apply,
        active: r.active
      }
    )
  end

  defp finish(row) do
    Map.put(row, :applies, if(row.applies_to == @loan, do: option(@loan), else: option(0)))
  end

  defp option(1), do: %{id: 1, code: "rateAppliesTo.loan", value: "Loan"}
  defp option(0), do: %{id: 0, code: "rateAppliesTo.invalid", value: "Invalid"}

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.rate.id.invalid",
        "Rate with identifier #{id} does not exist",
        [id]
      )
end
