defmodule ECBDeposits.DepositAccounts.Recurring do
  @moduledoc """
  What makes a recurring deposit account recurring, after Fineract's `RecurringDepositAccount`,
  `RecurringDepositScheduleInstallment` and the calendar (`m_calendar`, `m_calendar_instance`) every such account gets:
  the dates of its installments, the maturity amount that follows from paying them all on their days, the calendar
  that says how often they fall due and the rows of the schedule. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.DepositAccounts.Maturity
  alias ECBPlatform.Errors.ServerError
  alias ECBPlatform.TenantRepo

  @collection 1
  @savings_entity 5
  @weekdays ~w(MO TU WE TH FR SA SU)
  @frequencies %{0 => "DAILY", 1 => "WEEKLY", 2 => "MONTHLY", 3 => "YEARLY"}

  # --- the calendar's recurrence -------------------------------------------------------------------------

  @doc """
  The recurrence rule Fineract keeps for installments due every `every` days (0), weeks (1), months (2) or years (3):
  `FREQ=MONTHLY;INTERVAL=2`, a weekly one also naming the weekday of the day the deposits start on.
  """
  @spec recurrence(integer | nil, integer | nil, Date.t()) :: String.t()
  def recurrence(type, every, start) do
    frequency = Map.get(@frequencies, type, "INVALID")
    interval = if every != nil and every > 1, do: ";INTERVAL=#{every}", else: ""

    weekday =
      if type == 1, do: ";BYDAY=" <> Enum.at(@weekdays, Date.day_of_week(start) - 1), else: ""

    "FREQ=" <> frequency <> interval <> weekday
  end

  @doc "The unit and the number a recurrence rule stands for; a rule that names no known frequency is an error."
  @spec parse(String.t()) :: {integer, integer}
  def parse(recurrence) do
    parts = recurrence |> String.split(";") |> Map.new(&split_part/1)

    type =
      Enum.find_value(@frequencies, fn {id, name} -> if parts["FREQ"] == name, do: id end)

    # a calendar that has no valid frequency makes Fineract fail on reading it
    if type == nil, do: raise(ServerError)
    {type, parts |> Map.get("INTERVAL", "1") |> String.to_integer()}
  end

  defp split_part(part) do
    case String.split(part, "=", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, ""}
    end
  end

  # --- the installments -----------------------------------------------------------------------------------

  @doc "The day after `date` that falls `every` units of `type` later."
  @spec next_date(Date.t(), integer, integer) :: Date.t()
  def next_date(date, type, every), do: Maturity.date(date, every, type)

  @doc """
  The installments of a term that starts on `start` and ends on `maturity`: one on every day the recurrence names, from
  the start, for as long as it is before the maturity date, each worked out from the one before.
  """
  @spec installments(Date.t(), Date.t(), integer, integer, Decimal.t()) :: [map]
  def installments(start, maturity, type, every, amount) do
    start
    |> Stream.iterate(&next_date(&1, type, every))
    |> Enum.take_while(&(Date.compare(&1, maturity) == :lt))
    |> Enum.with_index(1)
    |> Enum.map(fn {due, number} -> %{number: number, due: due, amount: amount} end)
  end

  @doc "What all the installments come to."
  @spec total([map]) :: Decimal.t()
  def total(installments),
    do: Enum.reduce(installments, Decimal.new(0), &Decimal.add(&1.amount, &2))

  @doc """
  The deposit amount and the maturity amount of a recurring deposit paid in full on the due days: the interest the
  installments earn from their day until the day before the term ends, added to what they come to. `a` holds what
  `Maturity.interest/1` asks for (without `amount`) and the `installments`.
  """
  @spec maturity_amounts(map) :: {Decimal.t(), Decimal.t()}
  def maturity_amounts(a) do
    deposit = total(a.installments)

    deposits =
      Enum.map(a.installments, fn i ->
        %{id: i.number, type: 1, date: i.due, amount: i.amount, manual: false, overdraft: nil}
      end)

    interest = Maturity.interest_on(deposits, a)
    {deposit, Decimal.add(deposit, interest)}
  end

  # --- the rows ---------------------------------------------------------------------------------------------

  @doc "Replaces the schedule of an account with `installments`."
  @spec write_schedule!(struct, integer, [map]) :: :ok
  def write_schedule!(user, account_id, installments) do
    TenantRepo.delete_all(
      from(s in "m_mandatory_savings_schedule", where: s.savings_account_id == ^account_id)
    )

    now = DateTime.utc_now()

    rows =
      for i <- installments do
        %{
          savings_account_id: account_id,
          installment: i.number,
          duedate: i.due,
          deposit_amount: if(Decimal.eq?(i.amount, 0), do: nil, else: i.amount),
          completed_derived: false,
          created_by: user.id,
          last_modified_by: user.id,
          created_on_utc: now,
          last_modified_on_utc: now
        }
      end

    if rows != [], do: TenantRepo.insert_all("m_mandatory_savings_schedule", rows)
    :ok
  end

  @doc "The installments of an account, in order."
  @spec schedule(integer) :: [map]
  def schedule(account_id) do
    TenantRepo.all(
      from(s in "m_mandatory_savings_schedule",
        where: s.savings_account_id == ^account_id,
        order_by: s.installment,
        select: %{
          id: s.id,
          number: s.installment,
          due: s.duedate,
          amount: s.deposit_amount,
          paid: s.deposit_amount_completed_derived,
          completed: s.completed_derived
        }
      )
    )
  end

  @doc "Gives an account the calendar that says when its installments fall due."
  @spec create_calendar!(struct, integer, Date.t(), integer, integer) :: :ok
  def create_calendar!(user, account_id, start, type, every) do
    now = DateTime.utc_now()

    {1, [%{id: calendar_id}]} =
      TenantRepo.insert_all(
        "m_calendar",
        [
          %{
            title: "recurring_savings_#{account_id}",
            start_date: start,
            calendar_type_enum: @collection,
            repeating: true,
            recurrence: recurrence(type, every, start),
            created_by: user.id,
            last_modified_by: user.id,
            created_on_utc: now,
            last_modified_on_utc: now
          }
        ],
        returning: [:id]
      )

    TenantRepo.insert_all("m_calendar_instance", [
      %{calendar_id: calendar_id, entity_id: account_id, entity_type_enum: @savings_entity}
    ])

    :ok
  end

  @doc "Sets the start day and the rule of the calendar of an account."
  @spec update_calendar!(struct, integer, Date.t(), integer, integer) :: :ok
  def update_calendar!(user, account_id, start, type, every) do
    case calendar(account_id) do
      nil ->
        create_calendar!(user, account_id, start, type, every)

      %{id: id} ->
        TenantRepo.update_all(from(c in "m_calendar", where: c.id == ^id),
          set: [
            start_date: start,
            recurrence: recurrence(type, every, start),
            last_modified_by: user.id,
            last_modified_on_utc: DateTime.utc_now()
          ]
        )

        :ok
    end
  end

  @doc "The calendar of an account (the earliest one it has), or `nil`."
  @spec calendar(integer) :: map | nil
  def calendar(account_id) do
    TenantRepo.one(
      from(c in "m_calendar",
        join: i in "m_calendar_instance",
        on: i.calendar_id == c.id,
        where:
          i.entity_id == ^account_id and i.entity_type_enum == ^@savings_entity and
            c.calendar_type_enum == ^@collection,
        order_by: c.start_date,
        limit: 1,
        select: %{id: c.id, start_date: c.start_date, recurrence: c.recurrence}
      )
    )
  end

  @doc "Removes the calendar of an account."
  @spec delete_calendar!(integer) :: :ok
  def delete_calendar!(account_id) do
    ids =
      TenantRepo.all(
        from(i in "m_calendar_instance",
          where: i.entity_id == ^account_id and i.entity_type_enum == ^@savings_entity,
          select: i.calendar_id
        )
      )

    TenantRepo.delete_all(
      from(i in "m_calendar_instance",
        where: i.entity_id == ^account_id and i.entity_type_enum == ^@savings_entity
      )
    )

    TenantRepo.delete_all(from(c in "m_calendar_history", where: c.calendar_id in ^ids))
    TenantRepo.delete_all(from(c in "m_calendar", where: c.id in ^ids))
    :ok
  end
end
