defmodule ECBLoans.Delinquency.Actions do
  @moduledoc """
  Pausing and resuming the delinquency of a loan (`/loans/{id}/delinquency-actions`), after Fineract's
  `DelinquencyActionParseAndValidator` and `DelinquencyEffectivePauseHelperImpl`.

  A pause covers the days from its start date up to its end date; the days it covers do not count as delinquent. A
  resume, dated the business date, ends the pause it falls in on that date. The rows are in
  `m_loan_delinquency_action`.
  """
  import Ecto.Query

  alias ECBLoans.Delinquency.Classify
  alias ECBLoans.Loans
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result

  @resource "loanDelinquencyAction"
  @code "validation.msg.loanDelinquencyAction."
  @active 300

  @doc "The actions of loan `loan_id`, the first made first."
  @spec list(integer) :: [map]
  def list(loan_id) do
    from(a in "m_loan_delinquency_action",
      where: a.loan_id == ^loan_id,
      order_by: a.id,
      select: %{
        id: a.id,
        action: a.action,
        start: a.start_date,
        end: a.end_date,
        created_by: a.created_by,
        created_on: a.created_on_utc,
        updated_by: a.last_modified_by,
        updated_on: a.last_modified_on_utc
      }
    )
    |> TenantRepo.all()
  end

  @doc """
  The pauses of loan `loan_id` as they stand: each pause with the date it ended on if a resume fell in it (`id`, `start`,
  `end`), the first made first.
  """
  @spec effective(integer) :: [map]
  def effective(loan_id), do: effective_of(list(loan_id))

  defp effective_of(actions) do
    resumes = Enum.filter(actions, &(&1.action == "RESUME"))

    actions
    |> Enum.filter(&(&1.action == "PAUSE"))
    |> Enum.map(fn pause ->
      resume =
        Enum.find(resumes, fn r ->
          pause.id < r.id and Date.compare(pause.start, r.start) != :gt and
            Date.compare(r.start, pause.end) != :gt
        end)

      %{id: pause.id, start: pause.start, end: if(resume, do: resume.start, else: pause.end)}
    end)
  end

  @doc "The days of the pauses that fall from `from` (included) up to `to` (not included)."
  @spec paused_days([map], Date.t() | nil, Date.t() | nil) :: non_neg_integer
  def paused_days(_effective, nil, _to), do: 0
  def paused_days(_effective, _from, nil), do: 0

  def paused_days(effective, from, to) do
    if Date.compare(from, to) == :lt,
      do: effective |> Enum.map(&overlap_days(&1, from, to)) |> Enum.sum(),
      else: 0
  end

  defp overlap_days(pause, from, to) do
    if Date.compare(pause.start, to) != :lt or Date.compare(pause.end, from) != :gt,
      do: 0,
      else: Date.diff(Enum.min([pause.end, to], Date), Enum.max([pause.start, from], Date))
  end

  @doc "The pause periods to show on a loan: whether each is running today and its dates, earliest first."
  @spec periods(integer, Date.t()) :: [map]
  def periods(loan_id, today) do
    loan_id
    |> effective()
    |> Enum.sort_by(& &1.start, Date)
    |> Enum.map(fn p ->
      %{
        active: Date.compare(p.start, today) != :gt and Date.compare(today, p.end) != :gt,
        start: p.start,
        end: p.end
      }
    end)
  end

  @doc "Records a pause or a resume for loan `loan_id`."
  @spec create!(struct, integer, Params.t()) :: Result.t()
  def create!(user, loan_id, %Params{} = p) do
    loan = Loans.fetch!(loan_id)
    today = BusinessDate.current()
    saved = list(loan_id)
    effective = effective_of(saved)

    action = action(p)
    start = Params.date(p, "startDate")
    until = Params.date(p, "endDate")

    v = Validation.new(@resource)
    v = action_errors(v, p, action)

    v =
      if loan.loan_status_id == @active,
        do: v,
        else:
          Validation.add_error(
            v,
            @code <> "invalid.loan.state",
            "Delinquency actions can be created only for active loans.",
            "id",
            []
          )

    Validation.raise_if_errors!(v)

    case action do
      "PAUSE" -> validate_pause!(v, loan, start, until, effective)
      "RESUME" -> validate_resume!(v, today, start, until, saved, effective)
    end

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_loan_delinquency_action",
        [
          %{
            loan_id: loan_id,
            action: action,
            start_date: start,
            end_date: until,
            created_by: user.id,
            last_modified_by: user.id,
            created_on_utc: DateTime.utc_now(),
            last_modified_on_utc: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    # a pause that reaches back changes what the loan was delinquent for
    if action == "PAUSE" and Date.compare(start, today) == :lt,
      do: Classify.classify!(loan_id, user)

    Result.new(
      resource_id: id,
      loan_id: loan_id,
      office_id: loan.client_office_id,
      client_id: loan.client_id
    )
  end

  defp action(p) do
    case Params.string(p, "action") do
      text when text in [nil, ""] -> nil
      text -> String.upcase(text)
    end
  end

  defp action_errors(v, _p, nil),
    do:
      Validation.add_error(
        v,
        @code <> "action.cannot.be.blank",
        "Delinquency Action must not be null or empty",
        "action",
        []
      )

  defp action_errors(v, _p, text) when text in ["PAUSE", "RESUME"], do: v

  defp action_errors(v, p, _text) do
    Validation.add_error(
      v,
      @code <> "action.invalid.action",
      "Invalid Delinquency Action: " <> Params.string(p, "action"),
      "action",
      []
    )
  end

  defp validate_pause!(v, loan, start, until, effective) do
    v =
      v
      |> Validation.param("startDate", start)
      |> Validation.not_null()
      |> Validation.param("endDate", until)
      |> Validation.not_null()

    Validation.raise_if_errors!(v)

    if start == until do
      fail!(
        v,
        "pause.period.must.be.at.least.one.day",
        "Delinquency pause period must be at least one day",
        nil
      )
    end

    first = loan.disbursedon_date

    if first && Date.compare(first, start) == :gt do
      fail!(
        v,
        "startDate.before.disbursement",
        "Start date of pause period must be after first disbursal date",
        "startDate"
      )
    end

    overlapping =
      Enum.any?(effective, fn e ->
        Date.compare(e.start, e.end) == :lt and Date.compare(start, e.end) == :lt and
          Date.compare(until, e.start) == :gt
      end)

    if overlapping,
      do:
        fail!(
          v,
          "overlapping",
          "Delinquency pause period cannot overlap with another pause period",
          nil
        )
  end

  defp validate_resume!(v, today, start, until, saved, effective) do
    if start == nil do
      v
      |> Validation.param("startDate", start)
      |> Validation.not_null()
      |> Validation.raise_if_errors!()
    end

    if start != today do
      fail!(
        v,
        "startDate.resume.invalid.start.date",
        "Start date of the Resume Delinquency action must be the current business date",
        "startDate"
      )
    end

    if until != nil do
      fail!(
        v,
        "endDate.resume.should.have.no.end.date",
        "Resume Delinquency action can not have end date",
        "endDate"
      )
    end

    check_resume_unique!(v, start, saved, effective)

    on_pause =
      Enum.any?(effective, fn pause ->
        Date.compare(start, pause.start) != :lt and Date.compare(start, pause.end) != :gt
      end)

    unless on_pause,
      do:
        fail!(
          v,
          "resume.should.be.on.pause",
          "Resume Delinquency Action can only be created during an active pause",
          nil
        )
  end

  # a day can be resumed once, unless a pause is still running on it
  defp check_resume_unique!(v, start, saved, effective) do
    existing = Enum.any?(saved, &(&1.action == "RESUME" and &1.start == start))

    running =
      Enum.any?(effective, fn pause ->
        Date.compare(start, pause.start) != :lt and Date.compare(start, pause.end) == :lt
      end)

    if existing and not running,
      do:
        fail!(
          v,
          "resume.should.be.unique",
          "There is an existing Resume Delinquency Action on this date",
          nil
        )
  end

  defp fail!(v, code, message, parameter) do
    # a problem with the request as a whole is reported against `id`
    v
    |> Validation.add_error(@code <> code, message, parameter || "id", [])
    |> Validation.raise_if_errors!()
  end
end
