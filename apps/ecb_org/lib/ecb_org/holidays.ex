defmodule ECBOrg.Holidays do
  @moduledoc """
  Holidays (`m_holiday`), read side. A holiday applies to the offices listed in `m_holiday_office` and
  can move repayments that fall inside it to a specific date or to the next repayment date. Must run
  inside a tenant scope.

  A holiday is *pending* until someone activates it, then *active*; deleting it marks it *deleted*
  (the row stays, and is still listed, as in Fineract).
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @pending 100
  @active 300
  @deleted 600

  # The codes are Fineract's, including the one it gives to "deleted".
  @status %{
    @pending => %{
      code: "holidayStatusType.pending.for.activation",
      value: "Pending for activation"
    },
    @active => %{code: "holidayStatusType.active", value: "Active"},
    @deleted => %{code: "savingsAccountStatusType.transfer.in.progress", value: "Deleted"}
  }

  @rescheduling_types [
    %{
      id: 2,
      code: "rescheduletype.rescheduletospecificdate",
      value: "Reschedule to specified date"
    },
    %{
      id: 1,
      code: "rescheduletype.rescheduletonextrepaymentdate",
      value: "Reschedule to next repayment date"
    }
  ]

  @doc "The status numbers: `:pending`, `:active`, `:deleted`."
  @spec status(:pending | :active | :deleted) :: integer
  def status(:pending), do: @pending
  def status(:active), do: @active
  def status(:deleted), do: @deleted

  @doc "The ways a holiday can reschedule repayments."
  @spec rescheduling_types() :: [map]
  def rescheduling_types, do: @rescheduling_types

  @doc """
  The holidays that apply to an office, by id. Without an office there are none, as in Fineract.
  Options: `:from_date` keeps holidays starting on or after it, `:to_date` those ending on or before it.
  """
  @spec list(integer | nil, keyword) :: [map]
  def list(office_id, opts \\ [])
  def list(nil, _opts), do: []

  def list(office_id, opts) do
    base()
    |> join(:inner, [h], oh in "m_holiday_office",
      on: oh.holiday_id == h.id and oh.office_id == ^office_id
    )
    |> filter_from(opts[:from_date])
    |> filter_to(opts[:to_date])
    |> order_by([h], h.id)
    |> TenantRepo.all()
    |> Enum.map(&with_status/1)
  end

  @doc "One holiday, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([h], h.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      holiday -> {:ok, with_status(holiday)}
    end
  end

  @doc "Like `get/1` but raises the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, holiday} -> holiday
      {:error, error} -> raise error
    end
  end

  @doc "The ids of the offices a holiday applies to."
  @spec office_ids(integer) :: [integer]
  def office_ids(holiday_id),
    do:
      TenantRepo.all(
        from oh in "m_holiday_office", where: oh.holiday_id == ^holiday_id, select: oh.office_id
      )

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.holiday.id.invalid",
        "Holiday with identifier #{id} does not exist",
        [id]
      )

  defp base do
    from h in "m_holiday",
      select: %{
        id: h.id,
        name: h.name,
        description: h.description,
        from_date: h.from_date,
        to_date: h.to_date,
        repayments_rescheduled_to: h.repayments_rescheduled_to,
        status_id: h.status_enum,
        rescheduling_type: h.rescheduling_type
      }
  end

  defp with_status(h),
    do: Map.put(h, :status, @status |> Map.fetch!(h.status_id) |> Map.put(:id, h.status_id))

  defp filter_from(query, nil), do: query
  defp filter_from(query, date), do: where(query, [h], h.from_date >= ^date)

  defp filter_to(query, nil), do: query
  defp filter_to(query, date), do: where(query, [h], h.to_date <= ^date)
end
