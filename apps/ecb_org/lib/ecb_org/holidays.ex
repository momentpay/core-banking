defmodule ECBOrg.Holidays do
  @moduledoc """
  Holidays (`m_holiday`), read side. A holiday can move repayments that fall inside it to a specific
  date or to the next repayment date. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @status %{
    100 => %{code: "holidayStatusType.pending.activation", value: "Pending for activation"},
    300 => %{code: "holidayStatusType.active", value: "Active"},
    400 => %{code: "holidayStatusType.deleted", value: "Deleted"}
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

  @doc "The ways a holiday can reschedule repayments."
  @spec rescheduling_types() :: [map]
  def rescheduling_types, do: @rescheduling_types

  @doc "Holidays that are not deleted, by from-date. Option `:office_id` keeps those applying to that office."
  @spec list(keyword) :: [map]
  def list(opts \\ []) do
    from(h in "m_holiday",
      where: h.status_enum != 400,
      order_by: [h.from_date, h.id],
      select: %{
        id: h.id,
        name: h.name,
        from_date: h.from_date,
        to_date: h.to_date,
        repayments_rescheduled_to: h.repayments_rescheduled_to,
        status_id: h.status_enum,
        rescheduling_type: h.rescheduling_type,
        description: h.description
      }
    )
    |> filter_office(opts[:office_id])
    |> TenantRepo.all()
    |> Enum.map(fn h ->
      Map.put(h, :status, Map.put(Map.fetch!(@status, h.status_id), :id, h.status_id))
    end)
  end

  defp filter_office(query, nil), do: query

  defp filter_office(query, office_id) do
    where(
      query,
      [h],
      h.id in subquery(
        from(oh in "m_holiday_office", where: oh.office_id == ^office_id, select: oh.holiday_id)
      )
    )
  end
end
