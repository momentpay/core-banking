defmodule ECBOrg.WorkingDays do
  @moduledoc """
  The working week of the tenant (`m_working_days`): an iCalendar recurrence rule plus what to do with
  a repayment that falls on a non-working day. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @reschedule_options [
    %{id: 1, code: "RepaymentRescheduleType.same.day", value: "same day"},
    %{
      id: 2,
      code: "RepaymentRescheduleType.move.to.next.working.day",
      value: "move to next working day"
    },
    %{
      id: 3,
      code: "RepaymentRescheduleType.move.to.next.repayment.meeting.day",
      value: "move to next repayment meeting day"
    },
    %{
      id: 4,
      code: "RepaymentRescheduleType.move.to.previous.working.day",
      value: "move to previous working day"
    }
  ]

  @doc "The choices for what to do with a repayment on a non-working day."
  @spec reschedule_options() :: [map]
  def reschedule_options, do: @reschedule_options

  @doc "The working-days setting, or `nil` when none is stored."
  @spec get() :: map | nil
  def get do
    row =
      TenantRepo.one(
        from(w in "m_working_days",
          order_by: w.id,
          limit: 1,
          select: %{
            id: w.id,
            recurrence: w.recurrence,
            type_id: w.repayment_rescheduling_enum,
            extend_term_for_daily_repayments: w.extend_term_daily_repayments,
            extend_term_for_repayments_on_holidays: w.extend_term_holiday_repayment
          }
        )
      )

    row &&
      Map.put(
        row,
        :repayment_reschedule_type,
        Enum.find(@reschedule_options, &(&1.id == row.type_id))
      )
  end
end
