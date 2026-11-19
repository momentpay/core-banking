defmodule ECBLoans.Delinquency.Classify do
  @moduledoc """
  Putting a loan in a delinquency range, after Fineract's `LoanAccountDomainService.setLoanDelinquencyTag`,
  `DelinquencyWritePlatformServiceImpl` and `LoanDelinquencyDomainServiceImpl`.

  A loan is delinquent for the days since its oldest unpaid installment fell due, less the days of its grace on
  arrears ageing and less the days its delinquency was paused. When that is more than nothing and the loan's
  product has a bucket, the loan takes the range of the bucket that holds that many days (one with no maximum holds
  everything above its minimum; if none holds them, the loan keeps the range it has). When it is nothing, the loan
  leaves its range. Each stay in a range is a row of `m_loan_delinquency_tag_history`, open until the loan leaves.

  The classification is redone whenever the loan changes (`classify!/1`, called as its totals are worked out
  again) and for every active loan of a product with a bucket by the job "Loan Delinquency Classification"
  (`LA_DECL`).
  """
  import Ecto.Query

  alias ECBLoans.{Delinquency, Loans}
  alias ECBLoans.Delinquency.Actions
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @active 300
  # loans submitted, approved, closed or overpaid are not classified
  @unclassified [100, 200, 600, 601, 602, 700]

  @doc """
  How late loan `loan` is on `on`: the date its oldest overdue installment fell due, the days since (`overdue_days`)
  and the days of delinquency once grace and paused days are taken off (`delinquent_days`).
  """
  @spec collection(map, Date.t(), [map]) :: map
  def collection(loan, on, effective) do
    since =
      if loan.loan_status_id in @unclassified do
        nil
      else
        loan.id
        |> Loans.installments()
        |> Enum.find(&(&1.completed != true and Date.compare(&1.due_date, on) == :lt))
        |> then(&(&1 && &1.due_date))
      end

    overdue = if since, do: max(Date.diff(on, since), 0), else: 0
    grace = loan.grace_on_arrears_ageing || 0

    delinquent =
      if overdue > 0,
        do: max(overdue - Actions.paused_days(effective, since, on) - grace, 0),
        else: 0

    %{since: since, overdue_days: overdue, delinquent_days: delinquent, grace: grace}
  end

  @doc "Classifies loan `loan_id` as of the business date, as Fineract does when a loan changes."
  @spec classify!(integer, struct) :: :ok
  def classify!(loan_id, user) do
    loan = Loans.fetch!(loan_id)
    classify_loan!(loan, bucket_of(loan), user)
  end

  # a loan that is not active has no delinquent days, so it leaves its range
  defp classify_loan!(loan, bucket, user) do
    on = BusinessDate.current()
    effective = Actions.effective(loan.id)
    days = collection(loan, on, effective).delinquent_days

    cond do
      days > 0 and bucket != nil -> assign!(loan.id, bucket, days, on, user)
      days > 0 -> %{}
      true -> lift!(loan.id, on, user)
    end

    :ok
  end

  @doc """
  Puts the loan in the range of its product's bucket that holds `days`, as `command=assigndelinquency` does; the
  answer says which range it is in now and which it left.
  """
  @spec assign_now!(struct, integer) :: map
  def assign_now!(user, loan_id) do
    loan = Loans.fetch!(loan_id)
    on = BusinessDate.current()
    bucket = bucket_of(loan)
    data = collection(loan, on, Actions.effective(loan.id))

    changes =
      cond do
        bucket == nil -> nil
        data.delinquent_days > 0 -> assign!(loan.id, bucket, data.delinquent_days, on, user)
        true -> lift!(loan.id, on, user)
      end

    if changes, do: Map.put(changes, "overdueDays", data.delinquent_days), else: %{}
  end

  defp bucket_of(loan) do
    TenantRepo.one(
      from(p in "m_product_loan",
        where: p.id == ^loan.product_id,
        select: p.delinquency_bucket_id
      )
    )
  end

  defp assign!(loan_id, bucket, days, on, user) do
    range =
      bucket
      |> Delinquency.bucket_ranges()
      |> Enum.sort_by(& &1.min)
      |> Enum.find(&(&1.min <= days and (&1.max == nil or &1.max >= days)))

    if range, do: set!(loan_id, range, on, user), else: %{}
  end

  defp lift!(loan_id, on, user) do
    case open(loan_id) do
      nil ->
        %{}

      tag ->
        close!(tag.id, on, user)
        %{"previous" => Delinquency.range(tag.range_id)}
    end
  end

  defp set!(loan_id, range, on, user) do
    case open(loan_id) do
      %{range_id: id} = tag when id == range.id ->
        %{"current" => Delinquency.range(tag.range_id)}

      tag ->
        if tag, do: close!(tag.id, on, user)
        open!(loan_id, range.id, on, user)

        if tag,
          do: %{"previous" => Delinquency.range(tag.range_id), "current" => range},
          else: %{"current" => range}
    end
  end

  # --- the history ---------------------------------------------------------------------------------

  @doc "The stays of loan `loan_id` in ranges, the latest first."
  @spec history(integer) :: [map]
  def history(loan_id) do
    from(t in "m_loan_delinquency_tag_history",
      where: t.loan_id == ^loan_id,
      order_by: [desc: t.addedon_date, asc: t.id],
      select: %{
        id: t.id,
        range_id: t.delinquency_range_id,
        added: t.addedon_date,
        lifted: t.liftedon_date
      }
    )
    |> TenantRepo.all()
  end

  @doc "The range loan `loan_id` is in now, or `nil`."
  @spec current_range(integer) :: map | nil
  def current_range(loan_id) do
    case open(loan_id) do
      nil -> nil
      tag -> Delinquency.range(tag.range_id)
    end
  end

  defp open(loan_id) do
    from(t in "m_loan_delinquency_tag_history",
      where: t.loan_id == ^loan_id and is_nil(t.liftedon_date),
      order_by: [desc: t.id],
      limit: 1,
      select: %{id: t.id, range_id: t.delinquency_range_id}
    )
    |> TenantRepo.one()
  end

  defp close!(id, on, user) do
    TenantRepo.update_all(from(t in "m_loan_delinquency_tag_history", where: t.id == ^id),
      set: [
        liftedon_date: on,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now(),
        version: 2
      ]
    )
  end

  defp open!(loan_id, range_id, on, user) do
    now = DateTime.utc_now()

    TenantRepo.insert_all("m_loan_delinquency_tag_history", [
      %{
        delinquency_range_id: range_id,
        loan_id: loan_id,
        addedon_date: on,
        created_by: user.id,
        created_on_utc: now,
        version: 1,
        last_modified_by: user.id,
        last_modified_on_utc: now
      }
    ])
  end

  @doc "Whether loan `loan_id` is active (the job looks at active loans only)."
  @spec active?(map) :: boolean
  def active?(loan), do: loan.loan_status_id == @active
end
