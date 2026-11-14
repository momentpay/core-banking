defmodule ECBPlatform.BusinessDate do
  @moduledoc """
  The organisation's business date (`m_business_date`): the date the bank is working on, which can differ
  from the calendar date (the day is not closed until the close-of-business run). Two kinds exist:
  `BUSINESS_DATE` and `COB_DATE` (the date the close-of-business run works on, normally the day before).

  The whole feature is switched by the configuration `enable-business-date`. While it is off, every
  caller gets today's date from `current/0`. While it is on, `enable-automatic-cob-date-adjustment` makes
  setting the business date set the COB date to the day before. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Configuration
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.TenantRepo

  @types ~w(BUSINESS_DATE COB_DATE)
  @descriptions %{"BUSINESS_DATE" => "Business Date", "COB_DATE" => "Close of Business Date"}

  @doc "The kinds of business date."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "True when the business date feature is switched on."
  @spec enabled?() :: boolean
  def enabled?, do: Configuration.enabled?("enable-business-date")

  @doc """
  The date to work on: the stored business date (or COB date, with `type: "COB_DATE"`) when the feature is
  on and a date is stored, otherwise today (UTC).
  """
  @spec current(keyword) :: Date.t()
  def current(opts \\ []) do
    type = Keyword.get(opts, :type, "BUSINESS_DATE")

    with true <- enabled?(),
         {:ok, %{date: date}} <- get(type) do
      date
    else
      _ -> Date.utc_today()
    end
  end

  @doc "Every stored business date, by id."
  @spec list() :: [map]
  def list do
    from(b in "m_business_date", order_by: b.id, select: %{type: b.type, date: b.date})
    |> TenantRepo.all()
    |> Enum.map(&describe/1)
  end

  @doc "One business date by type name, or `{:error, ResourceNotFound}`."
  @spec get(String.t()) :: {:ok, map} | {:error, Exception.t()}
  def get(type) do
    if type in @types do
      query =
        from b in "m_business_date", where: b.type == ^type, select: %{type: b.type, date: b.date}

      case TenantRepo.one(query) do
        nil ->
          {:error,
           ResourceNotFound.new(
             "error.msg.businessdate.not.found",
             "Business date with type `#{type}` is not found.",
             [type, []]
           )}

        row ->
          {:ok, describe(row)}
      end
    else
      {:error,
       ResourceNotFound.new(
         "error.msg.businessdate.type.not.exist",
         "Business date with type `#{type}` does not exist.",
         [type, []]
       )}
    end
  end

  @doc """
  Sets a business date. Returns `%{type, description, date, changes}`, where `changes` lists every date
  that really changed (`nil` when none did). Raises when the feature is off.
  """
  @spec update!(String.t(), Date.t(), integer | nil) :: map
  def update!(type, %Date{} = date, user_id \\ nil) when type in @types do
    unless enabled?(),
      do:
        raise(DomainRuleViolation,
          code: "business.date.is.not.enabled",
          message: "Business date functionality is not enabled",
          args: ["business.date.is.not.enabled"]
        )

    changes = set(%{}, type, date, user_id)

    changes =
      if type == "BUSINESS_DATE" and
           Configuration.enabled?("enable-automatic-cob-date-adjustment"),
         do: set(changes, "COB_DATE", Date.add(date, -1), user_id),
         else: changes

    %{
      type: type,
      description: Map.fetch!(@descriptions, type),
      date: date,
      changes: if(changes == %{}, do: nil, else: changes)
    }
  end

  defp set(changes, type, date, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    naive = DateTime.to_naive(now)

    existing =
      TenantRepo.one(
        from b in "m_business_date",
          where: b.type == ^type,
          select: %{id: b.id, date: b.date, version: b.version}
      )

    case existing do
      nil ->
        TenantRepo.insert_all("m_business_date", [
          %{
            type: type,
            date: date,
            created_by: user_id || 0,
            created_date: naive,
            version: 0,
            last_modified_by: user_id || 0,
            lastmodified_date: naive,
            created_on_utc: now,
            last_modified_on_utc: now
          }
        ])

        Map.put(changes, type, date)

      %{date: ^date} ->
        changes

      %{id: id, version: version} ->
        TenantRepo.update_all(from(b in "m_business_date", where: b.id == ^id),
          set: [
            date: date,
            version: version + 1,
            last_modified_by: user_id || 0,
            lastmodified_date: naive,
            last_modified_on_utc: now
          ]
        )

        Map.put(changes, type, date)
    end
  end

  defp describe(%{type: type, date: date}),
    do: %{type: type, description: Map.fetch!(@descriptions, type), date: date}
end
