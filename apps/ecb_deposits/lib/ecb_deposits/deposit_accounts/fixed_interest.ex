defmodule ECBDeposits.DepositAccounts.FixedInterest do
  @moduledoc """
  The interest of a fixed deposit account, after Fineract's `FixedDepositAccount` and the deposit account write
  service: the rate its chart gives (lowered by the penalty when it is closed early), working interest out and posting
  it, the interest a premature closure posts, the interest posted at maturity and the premature amount.

  A fixed deposit earns until the day before it matures. Its last balance holds only until the day interest was last
  asked for (`balance_end_date_derived` of its last transaction, the business date of its activation to begin with):
  the premature amount and a premature closure count the days after that only from the next posting period on, as
  Fineract does. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.{DepositAccounts, Savings}
  alias ECBDeposits.DepositAccounts.{Maturity, Submit}
  alias ECBDeposits.Savings.{Balance, Interest, Postings, Transitions}
  alias ECBPlatform.{BusinessDate, TenantRepo}
  alias ECBPlatform.Commands.Result

  @active 300
  @matured 800
  @interest_types [3, 17]
  @till_withdrawal 2
  @whole_term 1

  # --- the account ----------------------------------------------------------------------------------

  @doc "The fixed deposit account `id` for a command: it must exist, and its client must be active."
  @spec fixed!(integer) :: map
  def fixed!(id) do
    account = Submit.writable!(id)
    Transitions.account!(id)
    account
  end

  @doc "The day the deposit starts: its activation, or the application until it is activated."
  @spec start(map) :: Date.t()
  def start(account), do: account.activatedon_date || account.submittedon_date

  @doc "The day the term of the deposit ends."
  @spec maturity(map) :: Date.t() | nil
  def maturity(%{term: t} = account),
    do: Maturity.date(start(account), t.deposit_period, t.deposit_period_frequency)

  @doc "The last day the deposit earns interest: the day before it matures."
  @spec last_day(map) :: Date.t() | nil
  def last_day(account), do: account |> maturity() |> then(&(&1 && Date.add(&1, -1)))

  @doc "Whether the account is one that interest is worked out for: active, or matured and not yet closed."
  @spec earning?(map) :: boolean
  def earning?(account), do: account.status_enum in [@active, @matured]

  # --- the rate -------------------------------------------------------------------------------------

  @doc """
  The annual rate (a percentage) the deposit earns. With a chart it is the rate of the slab the term and amount fall
  in; when the deposit is closed early (`:premature`) and the product penalises that, the term is the one up to
  the end of the whole term or up to `closed_to`, as the penalty says, and the penalty is taken off the rate.
  """
  @spec rate(map, :normal | :premature, Date.t() | nil) :: Decimal.t()
  def rate(account, mode, closed_to \\ nil) do
    case DepositAccounts.chart(account.id) do
      nil -> account.nominal_annual_interest_rate
      chart -> chart_rate(account, chart, mode, closed_to)
    end
  end

  defp chart_rate(%{term: t} = account, chart, mode, closed_to) do
    start = start(account)
    maturity = maturity(account)

    if mode == :premature and t.pre_closure_penal_applicable == true do
      close =
        case t.pre_closure_penal_interest_on do
          @whole_term -> Date.add(maturity, -1)
          @till_withdrawal -> closed_to
          _ -> maturity
        end

      chart.slabs
      |> Maturity.rate(t.deposit_amount, start, close)
      |> Decimal.sub(t.pre_closure_penal_interest || Decimal.new(0))
      |> then(&if(Decimal.lt?(&1, 0), do: Decimal.new(0), else: &1))
    else
      Maturity.rate(chart.slabs, t.deposit_amount, start, maturity)
    end
  end

  @doc """
  The account with the rate it earns now, which Fineract also keeps on the account (so the rate the account shows is
  that of whatever was worked out last), and with the day interest starts.
  """
  @spec with_rate!(map, :normal | :premature, Date.t() | nil) :: map
  def with_rate!(account, mode, closed_to \\ nil) do
    rate = rate(account, mode, closed_to)

    if DepositAccounts.chart(account.id) != nil,
      do:
        TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account.id),
          set: [nominal_annual_interest_rate: rate]
        )

    %{
      account
      | nominal_annual_interest_rate: rate,
        start_interest_calculation_date: start(account)
    }
  end

  # --- the balances' last day -------------------------------------------------------------------------

  @doc "Keeps the day the last balance of the account holds until."
  @spec store_end!(integer, Date.t()) :: :ok
  def store_end!(id, date) do
    case last_balance(id) do
      nil ->
        :ok

      %{id: tx_id} ->
        TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id == ^tx_id),
          set: [balance_end_date_derived: date]
        )

        :ok
    end
  end

  defp stored_end(id) do
    case last_balance(id) do
      nil -> nil
      %{ends: ends, date: date} -> ends || date
    end
  end

  defp last_balance(id) do
    from(t in "m_savings_account_transaction",
      where:
        t.savings_account_id == ^id and not t.is_reversed and not t.is_reversal and
          t.transaction_type_enum not in ^@interest_types,
      order_by: [desc: t.transaction_date, desc: t.id],
      limit: 1,
      select: %{id: t.id, date: t.transaction_date, ends: t.balance_end_date_derived}
    )
    |> TenantRepo.one()
  end

  # --- the commands ---------------------------------------------------------------------------------

  @doc "`calculateInterest`: works the interest out up to today (or the last day of the term) and notes what it is."
  @spec calculate!(struct, integer) :: Result.t()
  def calculate!(user, id) do
    account = fixed!(id)

    if earning?(account) do
      up_to = earliest(BusinessDate.current(), last_day(account))
      account = with_rate!(account, :normal)

      plan =
        Interest.plan(account, Balance.live(id), precision: 15, mode: :calculate, up_to: up_to)

      Postings.settle!(user, account, plan)
      store_end!(id, up_to)
    end

    result(account)
  end

  @doc "`postInterest`: posts the interest of the posting periods that have ended."
  @spec post!(struct, integer) :: Result.t()
  def post!(user, id) do
    account = fixed!(id)

    if earning?(account) do
      up_to = earliest(BusinessDate.current(), last_day(account))
      account = with_rate!(account, :normal)

      plan =
        Interest.plan(account, Balance.live(id),
          precision: 10,
          mode: :post,
          up_to: up_to,
          post_until: BusinessDate.current()
        )

      Postings.settle!(user, account, plan)
      store_end!(id, up_to)
    end

    result(account)
  end

  @doc """
  Posts the interest of the whole term, as Fineract does when a deposit matures: one posting for each posting period,
  the last on the maturity date.
  """
  @spec post_maturity_interest!(struct, map) :: :ok
  def post_maturity_interest!(user, account) do
    if earning?(account) do
      up_to = last_day(account)
      account = with_rate!(account, :normal)

      plan =
        Interest.plan(account, Balance.live(account.id),
          precision: 16,
          mode: :post,
          up_to: up_to,
          post_until: maturity(account),
          cap_dates: true
        )

      Postings.settle!(user, account, plan)
      store_end!(account.id, up_to)
    end

    :ok
  end

  @doc """
  What a premature closure leaves to post: the interest the deposit earns until the day before `closed_on` at the
  penalised rate, less what was posted. The premature amount is the balance with that in place of what was posted.
  """
  @spec premature!(map, Date.t()) :: %{
          earned: Decimal.t(),
          posted: Decimal.t(),
          balance: Decimal.t()
        }
  def premature!(account, closed_on) do
    to = Date.add(closed_on, -1)
    account = with_rate!(account, :premature, to)
    live = Balance.live(account.id)

    earned =
      if Date.compare(to, start(account)) == :lt or not Interest.calculating?(account) do
        Decimal.new(0)
      else
        plan =
          Interest.plan(account, live,
            precision: 16,
            mode: :calculate,
            up_to: to,
            balances_until: stored_end(account.id)
          )

        plan.earned || Decimal.new(0)
      end

    # the interest worked out is the account's own, and none of it is earned until interest is asked for
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account.id),
      set: [
        total_interest_earned_derived: nil,
        last_interest_calculation_date: BusinessDate.current()
      ]
    )

    posted =
      live
      |> Enum.filter(&(&1.type == 3))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))

    fresh = Savings.fetch!(account.id)
    %{earned: earned, posted: posted, balance: fresh.account_balance_derived}
  end

  @doc "The amount a deposit would pay if closed early on `closed_on`."
  @spec premature_amount(map, Date.t()) :: Decimal.t()
  def premature_amount(account, closed_on) do
    %{earned: earned, posted: posted, balance: balance} = premature!(account, closed_on)
    balance |> Decimal.sub(posted) |> Decimal.add(earned)
  end

  @doc """
  Posts what an early closure on `closed_on` has earned but not had posted, as one posting of interest on that day,
  and notes the balance and the day as the amount and date the deposit matures with.
  """
  @spec post_premature_interest!(struct, map, Date.t()) :: :ok
  def post_premature_interest!(user, account, closed_on) do
    %{earned: earned, posted: posted} = premature!(account, closed_on)
    remaining = Decimal.sub(earned, posted)

    if not Decimal.eq?(remaining, 0) do
      row = %{
        id: 1_000_000_000_000_001,
        type: 3,
        date: closed_on,
        amount: remaining,
        manual: false,
        overdraft: nil,
        payment_detail_id: nil,
        ref_no: nil
      }

      plan = %{
        calculating?: false,
        earned: nil,
        up_to: closed_on,
        reverse: [],
        create: [%{kind: :posting, reversed?: false, row: row}],
        live_after: [],
        posted_till: nil
      }

      Postings.settle!(user, account, plan)
    end

    balance = Savings.fetch!(account.id).account_balance_derived

    TenantRepo.update_all(
      from(t in "m_deposit_account_term_and_preclosure",
        where: t.savings_account_id == ^account.id
      ),
      set: [maturity_amount: balance, maturity_date: closed_on]
    )

    :ok
  end

  # --- helpers --------------------------------------------------------------------------------------

  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(Date.compare(a, b) == :gt, do: b, else: a)

  defp result(account),
    do:
      Result.new(
        resource_id: account.id,
        savings_id: account.id,
        office_id: account.client_office_id,
        client_id: account.client_id
      )
end
