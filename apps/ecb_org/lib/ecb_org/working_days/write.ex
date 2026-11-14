defmodule ECBOrg.WorkingDays.Write do
  @moduledoc """
  Changing the working week (`m_working_days`), following Fineract 1.16's typed working-days update.

  The request carries the recurrence rule (required) and optionally what to do with a repayment on a
  non-working day and whether the term is extended. The answer echoes the request values beside
  `resourceId` and lists the real changes, including `resourceId`, under `changes` (a quirk of that
  release that clients may rely on).
  """
  import Ecto.Query

  alias ECBOrg.WorkingDays
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DataIntegrity, ResourceNotFound}
  alias ECBPlatform.{Params, RecurrenceRule, TenantRepo, Validation}

  @doc "Applies the update `params` describe."
  @spec update!(Params.t()) :: Result.t()
  def update!(%Params{} = params) do
    # values of the wrong type are refused first, as when the request is read into its typed form
    extend_daily = Params.strict_boolean(params, "extendTermForDailyRepayments")
    extend_holidays = Params.strict_boolean(params, "extendTermForRepaymentsOnHolidays")
    type = Params.integer(params, "repaymentRescheduleType")
    recurrence = Params.string(params, "recurrence")

    Validation.new("workingdays")
    |> Validation.param("recurrence", recurrence)
    |> Validation.not_null()
    |> Validation.param("repaymentRescheduleType", type)
    |> Validation.ignore_if_null()
    |> Validation.in_range(1, 4)
    |> Validation.raise_if_errors!()

    stored = WorkingDays.get() || raise not_found()
    check_rule!(recurrence)

    changes =
      [
        {"recurrence", :recurrence, recurrence, stored.recurrence, true},
        {"repaymentRescheduleType", :repayment_rescheduling_enum, type, stored.type_id, false},
        {"extendTermForDailyRepayments", :extend_term_daily_repayments, extend_daily,
         stored.extend_term_for_daily_repayments, false},
        {"extendTermForRepaymentsOnHolidays", :extend_term_holiday_repayment, extend_holidays,
         stored.extend_term_for_repayments_on_holidays, false}
      ]
      |> Enum.filter(fn {_key, _column, new, old, always?} ->
        (always? or new != nil) and new != old
      end)

    unless changes == [] do
      set = for {_key, column, new, _old, _always} <- changes, do: {column, new}
      TenantRepo.update_all(from(w in "m_working_days", where: w.id == ^stored.id), set: set)
    end

    echoed =
      [
        {"recurrence", recurrence},
        {"repaymentRescheduleType", type},
        {"extendTermForDailyRepayments", extend_daily},
        {"extendTermForRepaymentsOnHolidays", extend_holidays}
      ]
      |> Enum.reject(fn {_key, value} -> value == nil end)
      |> Map.new()

    shown =
      for {key, _column, new, _old, _always} <- changes,
          into: %{"resourceId" => stored.id},
          do: {key, new}

    Result.new(resource_id: stored.id, extra: echoed, changes: shown)
  end

  defp check_rule!(recurrence) do
    case RecurrenceRule.validate(recurrence) do
      :ok ->
        :ok

      {:error, :invalid} ->
        raise DataIntegrity,
          code: "error.msg.invalid.recurring.rule",
          message: "The Recurring Rule value: #{recurrence} is not valid.",
          parameter: "recurrence",
          args: [recurrence]

      {:error, :parse, detail} ->
        raise DataIntegrity,
          code: "error.msg.recurring.rule.parsing.error",
          message: "Error in passing the Recurring Rule value: #{recurrence}",
          parameter: "recurrence",
          args: [detail]
    end
  end

  defp not_found,
    do:
      ResourceNotFound.new(
        "error.msg.workingdays.not.found",
        "Working days are not configured",
        []
      )
end
