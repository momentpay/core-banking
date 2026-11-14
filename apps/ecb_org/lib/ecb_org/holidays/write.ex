defmodule ECBOrg.Holidays.Write do
  @moduledoc """
  Creating, changing, activating and deleting holidays, following Fineract's holiday service and
  `Holiday` entity.

  A holiday that moves repayments to a specific date must name a date that is a working day, outside the
  holiday, and within 30 days of it. A holiday is editable freely while it is pending; once active only
  its name, description and rescheduling type can change.
  """
  import Ecto.Query

  alias ECBOrg.Holidays
  alias ECBPlatform.Changes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformApiDataValidation, ResourceNotFound}
  alias ECBPlatform.{Integrity, Params, RecurrenceRule, TenantRepo, Validation}

  @supported ~w(locale dateFormat name fromDate toDate description offices repaymentsRescheduledTo reschedulingType)
  @specific_date 2
  @next_repayment 1

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the holiday `params` describe; it starts pending."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    params = Params.check_supported!(params, @supported)

    name = Params.string(params, "name")
    from = Params.date(params, "fromDate")
    to = Params.date(params, "toDate")

    type =
      if Params.exists?(params, "reschedulingType"),
        do: Params.integer(params, "reschedulingType")

    repay_to =
      if type in [nil, @specific_date], do: Params.date(params, "repaymentsRescheduledTo")

    {office_ids, office_problems} = offices_param(params)

    validation =
      Validation.new("holiday")
      |> Validation.param("name", name)
      |> Validation.not_null()
      |> Validation.max_length(100)
      |> Validation.param("fromDate", from)
      |> Validation.not_null()
      |> Validation.param("toDate", to)
      |> Validation.not_null()

    validation =
      if type in [nil, @specific_date],
        do:
          validation
          |> Validation.param("repaymentsRescheduledTo", repay_to)
          |> Validation.not_null(),
        else: validation

    validation
    |> add_office_errors(office_problems, office_ids)
    |> Validation.raise_if_errors!()

    if repay_to, do: check_dates!(from, to, repay_to)

    office_ids = existing_offices!(office_ids)

    {1, [%{id: id}]} =
      Integrity.translate(
        fn ->
          TenantRepo.insert_all(
            "m_holiday",
            [
              %{
                name: String.trim(name),
                from_date: from,
                to_date: to,
                repayments_rescheduled_to: repay_to,
                rescheduling_type: type || @specific_date,
                status_enum: Holidays.status(:pending),
                processed: false,
                description: String.trim(Params.command_string(params, "description"))
              }
            ],
            returning: [:id]
          )
        end,
        %{
          "holiday_name" =>
            {"error.msg.holiday.duplicate.name", "Holiday with name `#{name}` already exists",
             "name", [name]}
        },
        {"error.msg.office.unknown.data.integrity.issue",
         "Unknown data integrity issue with resource."}
      )

    set_offices!(id, office_ids)
    Result.new(resource_id: id)
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes holiday `id`. The result lists what changed."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    params = Params.check_supported!(params, @supported)
    validate_for_update!(params)

    holiday = Holidays.fetch!(id)
    pending? = holiday.status_id == Holidays.status(:pending)

    changes =
      Changes.new()
      |> Changes.text(params, "name", :name, holiday.name)
      |> Changes.text(params, "description", :description, holiday.description)
      |> change_type(params, holiday)

    {changes, new_offices} = apply_pending_rules!(changes, params, holiday, pending?)

    dates = %{
      from: new_value(changes, :from_date, holiday.from_date),
      to: new_value(changes, :to_date, holiday.to_date),
      repay_to: new_value(changes, :repayments_rescheduled_to, holiday.repayments_rescheduled_to)
    }

    check_update_dates!(dates)

    {changes, office_ids} = settle_offices!(changes, holiday, new_offices)

    unless Changes.set(changes) == [] do
      guard_name(Params.string(params, "name"), fn ->
        TenantRepo.update_all(from(h in "m_holiday", where: h.id == ^id),
          set: Changes.set(changes)
        )
      end)
    end

    if office_ids, do: set_offices!(id, office_ids)
    Result.new(resource_id: id, changes: Changes.public(changes))
  end

  defp change_type(changes, params, holiday) do
    new =
      if Params.exists?(params, "reschedulingType"),
        do: Params.integer(params, "reschedulingType")

    cond do
      new == nil or new == holiday.rescheduling_type ->
        changes

      new == @next_repayment ->
        changes
        |> Changes.integer(
          params,
          "reschedulingType",
          :rescheduling_type,
          holiday.rescheduling_type
        )
        |> Changes.store(:repayments_rescheduled_to, nil)

      true ->
        Changes.integer(
          changes,
          params,
          "reschedulingType",
          :rescheduling_type,
          holiday.rescheduling_type
        )
    end
  end

  # Dates and offices can only change while the holiday is pending.
  defp apply_pending_rules!(changes, params, holiday, true) do
    changes =
      changes
      |> Changes.date(params, "fromDate", :from_date, holiday.from_date)
      |> Changes.date(params, "toDate", :to_date, holiday.to_date)
      |> Changes.date(
        params,
        "repaymentsRescheduledTo",
        :repayments_rescheduled_to,
        holiday.repayments_rescheduled_to
      )

    case Params.value(params, "offices") do
      list when is_list(list) ->
        {Changes.show(changes, "offices", Jason.encode!(list)), offices_param(params) |> elem(0)}

      _ ->
        {changes, nil}
    end
  end

  defp apply_pending_rules!(changes, params, holiday, false) do
    validation =
      Validation.new("holiday.update")
      |> locked("fromDate", Params.changed_date?(params, "fromDate", holiday.from_date))
      |> locked("toDate", Params.changed_date?(params, "toDate", holiday.to_date))
      |> locked(
        "repaymentsRescheduledTo",
        Params.changed_date?(params, "repaymentsRescheduledTo", holiday.repayments_rescheduled_to)
      )
      |> locked("repaymentsRescheduledTo", Params.exists?(params, "offices"))

    Validation.raise_if_errors!(validation)
    {changes, nil}
  end

  defp locked(validation, _parameter, false), do: validation

  defp locked(validation, parameter, true) do
    validation
    |> Validation.param(parameter, nil)
    |> Validation.fail_with_code("cannot.edit.holiday.in.active.state")
  end

  # The offices only count as a change when the set really differs.
  defp settle_offices!(changes, _holiday, nil), do: {changes, nil}

  defp settle_offices!(changes, holiday, office_ids) do
    ids = existing_offices!(office_ids)

    if Enum.sort(ids) == Enum.sort(Holidays.office_ids(holiday.id)),
      do: {%{changes | public: Map.delete(changes.public, "offices")}, nil},
      else: {changes, ids}
  end

  defp validate_for_update!(params) do
    validation = Validation.new("holiday")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_null()
          |> Validation.max_length(100),
        else: validation

    validation =
      Enum.reduce(~w(fromDate toDate repaymentsRescheduledTo), validation, fn key, v ->
        if Params.exists?(params, key),
          do: v |> Validation.param(key, Params.date(params, key)) |> Validation.not_null(),
          else: v
      end)

    validation =
      if Params.exists?(params, "offices") do
        {office_ids, problems} = offices_param(params)
        add_office_errors(validation, problems, office_ids)
      else
        validation
      end

    Validation.raise_if_errors!(validation)
  end

  # --- activate and delete --------------------------------------------------------------------

  @doc "Activates a pending holiday."
  @spec activate!(integer) :: Result.t()
  def activate!(id) do
    holiday = Holidays.fetch!(id)

    if holiday.status_id != Holidays.status(:pending),
      do: refuse!("holiday.activate", "not.in.pending.for.activation.state")

    set_status!(id, Holidays.status(:active))
    Result.new(resource_id: id)
  end

  @doc "Deletes a holiday: it is kept, marked deleted."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    holiday = Holidays.fetch!(id)

    if holiday.status_id == Holidays.status(:deleted),
      do: refuse!("holiday.delete", "already.in.deleted.state")

    set_status!(id, Holidays.status(:deleted))
    Result.new(resource_id: id)
  end

  defp set_status!(id, status),
    do:
      TenantRepo.update_all(from(h in "m_holiday", where: h.id == ^id),
        set: [status_enum: status]
      )

  defp refuse!(resource, problem) do
    error =
      ECBPlatform.Errors.parameter_error(
        "validation.msg.#{resource}.#{problem}",
        "Failed data validation due to: #{problem}.",
        nil,
        [nil, []]
      )

    raise PlatformApiDataValidation, errors: [error]
  end

  # --- dates ----------------------------------------------------------------------------------

  # On create the checks only run when a date to move repayments to was given.
  defp check_dates!(from, to, repay_to) do
    if Date.compare(to, from) == :lt,
      do:
        rule!(
          "to.date.cannot.be.before.from.date",
          "To Date date cannot be before the From Date.",
          [Date.to_iso8601(from), Date.to_iso8601(to)]
        )

    check_repayment_date!(from, to, repay_to)
  end

  # On update the holiday as it would be is checked, whatever was sent.
  defp check_update_dates!(%{from: from, to: to, repay_to: repay_to}) do
    if Date.compare(to, from) == :lt,
      do:
        rule!(
          "to.date.cannot.be.before.from.date",
          "To Date date cannot be before the From Date.",
          [Date.to_iso8601(from), Date.to_iso8601(to)]
        )

    if repay_to, do: check_repayment_date!(from, to, repay_to)
  end

  defp check_repayment_date!(from, to, repay_to) do
    if Date.compare(repay_to, from) != :lt and Date.compare(repay_to, to) != :gt,
      do:
        rule!(
          "repayments.rescheduled.date.should.be.before.from.date.or.after.to.date",
          "Repayments rescheduled date should be before from date or after to date.",
          [Date.to_iso8601(repay_to)]
        )

    unless working_day?(repay_to),
      do:
        rule!(
          "repayments.rescheduled.date.should.not.fall.on.non.working.day",
          "Repayments rescheduled date should not fall on non working days",
          [Date.to_iso8601(repay_to)]
        )

    if Date.compare(repay_to, Date.add(from, -30)) == :lt or
         Date.compare(repay_to, Date.add(to, 30)) == :gt,
       do:
         rule!(
           "repayments.rescheduled.to.must.be.within.range",
           "Repayments Rescheduled to date must be within 30 days before or after from and to dates",
           [Date.to_iso8601(from), Date.to_iso8601(to), Date.to_iso8601(repay_to)]
         )
  end

  defp working_day?(date) do
    case ECBOrg.WorkingDays.get() do
      nil -> true
      %{recurrence: recurrence} -> RecurrenceRule.working_day?(recurrence, date)
    end
  end

  defp rule!(postfix, message, args),
    do:
      raise(DomainRuleViolation,
        code: "error.msg.holiday." <> postfix,
        message: message,
        args: args
      )

  defp new_value(changes, column, existing) do
    case Enum.find(Changes.set(changes), fn {key, _} -> key == column end) do
      {_, value} -> value
      nil -> existing
    end
  end

  # --- offices --------------------------------------------------------------------------------

  # The `offices` array as office ids, and how many entries had no `officeId`.
  defp offices_param(params) do
    case Params.value(params, "offices") do
      [_ | _] = list ->
        ids = for %{} = entry <- list, do: entry |> Map.get("officeId") |> to_id()
        {Enum.reject(ids, &is_nil/1), Enum.count(ids, &is_nil/1)}

      _ ->
        {nil, 0}
    end
  end

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  defp add_office_errors(validation, missing_ids, office_ids) do
    validation =
      Enum.reduce(List.duplicate(nil, missing_ids), validation, fn _, v ->
        v |> Validation.param("offices", nil) |> Validation.not_null()
      end)

    value = if office_ids in [nil, []] and missing_ids == 0, do: nil, else: office_ids
    validation |> Validation.param("offices", value) |> Validation.not_null()
  end

  defp existing_offices!(office_ids) do
    ids = Enum.uniq(office_ids || [])
    found = TenantRepo.all(from o in "m_office", where: o.id in ^ids, select: o.id)

    case Enum.find(ids, &(&1 not in found)) do
      nil ->
        ids

      missing ->
        raise ResourceNotFound,
          code: "error.msg.office.id.invalid",
          message: "Office with identifier #{missing} does not exist",
          args: [missing]
    end
  end

  defp set_offices!(holiday_id, office_ids) do
    TenantRepo.delete_all(from oh in "m_holiday_office", where: oh.holiday_id == ^holiday_id)

    TenantRepo.insert_all(
      "m_holiday_office",
      for(office_id <- office_ids, do: %{holiday_id: holiday_id, office_id: office_id})
    )
  end

  defp guard_name(name, fun) do
    Integrity.translate(
      fun,
      %{
        "holiday_name" =>
          {"error.msg.holiday.duplicate.name", "Holiday with name `#{name}` already exists",
           "name", [name]}
      },
      {"error.msg.office.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end
end
