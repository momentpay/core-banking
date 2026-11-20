defmodule ECBDeposits.DepositAccounts do
  @moduledoc """
  Fixed and recurring deposit accounts (`m_savings_account` of deposit type 200 or 300), the read side, after
  Fineract's `DepositAccountReadPlatformServiceImpl`. A deposit account is a savings account that also has a term and
  a pre-closure penalty (`m_deposit_account_term_and_preclosure`) and a copy of the interest rate chart it was
  opened on. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.{DepositEnums, Savings}
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "The deposit type of a kind of account."
  @spec type(:fixed | :recurring) :: integer
  def type(:fixed), do: DepositEnums.fixed()
  def type(:recurring), do: DepositEnums.recurring()

  @doc "One account of the kind with its term, or `nil`."
  @spec get(:fixed | :recurring, integer) :: map | nil
  def get(kind, id) do
    case Savings.get(id) do
      %{deposit_type_enum: t} = account -> if t == type(kind), do: with_term(account)
      _ -> nil
    end
  end

  @doc "Like `get/2` but raises the not-found error."
  @spec fetch!(:fixed | :recurring, integer) :: map
  def fetch!(kind, id), do: get(kind, id) || raise(not_found(kind, id))

  @doc "The accounts of the kind, by id, with their terms."
  @spec list(:fixed | :recurring) :: [map]
  def list(kind) do
    {_total, accounts} = Savings.list(order_by: "id", sort: "ASC")
    t = type(kind)
    for %{deposit_type_enum: ^t} = account <- accounts, do: with_term(account)
  end

  @doc "The active savings accounts of a client (to pay a closed deposit into), by id."
  @spec active_savings(integer) :: [map]
  def active_savings(client_id) do
    TenantRepo.all(
      from(a in "m_savings_account",
        where:
          a.client_id == ^client_id and a.status_enum == 300 and
            a.deposit_type_enum == ^DepositEnums.savings(),
        order_by: a.id,
        select: %{id: a.id, account_no: a.account_no, product_id: a.product_id}
      )
    )
  end

  @doc "The error for an account of the kind that does not exist."
  @spec not_found(:fixed | :recurring, term) :: Exception.t()
  def not_found(:fixed, id),
    do:
      ResourceNotFound.new(
        "error.msg.depositaccounttype.fixeddeposit.id.invalid",
        "Depositaccounttype.fixeddeposit account with identifier #{id} does not exist",
        [id]
      )

  def not_found(:recurring, id),
    do:
      ResourceNotFound.new(
        "error.msg.depositaccounttype.recurringdeposit.id.invalid",
        "Depositaccounttype.recurringdeposit account with identifier #{id} does not exist",
        [id]
      )

  defp with_term(account), do: Map.put(account, :term, term(account.id))

  @doc "The term and pre-closure penalty of an account, as stored."
  @spec term(integer) :: map | nil
  def term(account_id) do
    TenantRepo.one(
      from(t in "m_deposit_account_term_and_preclosure",
        where: t.savings_account_id == ^account_id,
        select: %{
          id: t.id,
          min_deposit_term: t.min_deposit_term,
          max_deposit_term: t.max_deposit_term,
          min_deposit_term_type: t.min_deposit_term_type_enum,
          max_deposit_term_type: t.max_deposit_term_type_enum,
          in_multiples_of_deposit_term: t.in_multiples_of_deposit_term,
          in_multiples_of_deposit_term_type: t.in_multiples_of_deposit_term_type_enum,
          pre_closure_penal_applicable: t.pre_closure_penal_applicable,
          pre_closure_penal_interest: t.pre_closure_penal_interest,
          pre_closure_penal_interest_on: t.pre_closure_penal_interest_on_enum,
          deposit_period: t.deposit_period,
          deposit_period_frequency: t.deposit_period_frequency_enum,
          deposit_amount: t.deposit_amount,
          maturity_amount: t.maturity_amount,
          maturity_date: t.maturity_date,
          on_closure: t.on_account_closure_enum,
          expected_first_deposit_on: t.expected_firstdepositon_date,
          transfer_interest: t.transfer_interest_to_linked_account,
          transfer_to_savings_id: t.transfer_to_savings_account_id
        }
      )
    )
  end

  @doc "The chart an account was opened on, with its slabs and their incentives, or `nil`."
  @spec chart(integer) :: map | nil
  def chart(account_id) do
    case TenantRepo.one(
           from(c in "m_savings_account_interest_rate_chart",
             where: c.savings_account_id == ^account_id,
             select: %{
               id: c.id,
               name: c.name,
               description: c.description,
               from_date: c.from_date,
               end_date: c.end_date,
               grouping: c.is_primary_grouping_by_amount
             }
           )
         ) do
      nil -> nil
      chart -> Map.put(chart, :slabs, slabs(chart.id))
    end
  end

  defp slabs(chart_id) do
    from(s in "m_savings_account_interest_rate_slab",
      where: s.savings_account_interest_rate_chart_id == ^chart_id,
      order_by: s.id,
      select: %{
        id: s.id,
        description: s.description,
        period_type: s.period_type_enum,
        from_period: s.from_period,
        to_period: s.to_period,
        amount_from: s.amount_range_from,
        amount_to: s.amount_range_to,
        rate: s.annual_interest_rate,
        currency_code: s.currency_code
      }
    )
    |> TenantRepo.all()
    |> Enum.sort_by(&{&1.from_period || 0, &1.amount_from || Decimal.new(0), &1.id}, &sorted?/2)
    |> Enum.map(&Map.put(&1, :incentives, incentives(&1.id)))
  end

  # slabs by period, then by amount
  defp sorted?({p1, a1, i1}, {p2, a2, i2}) do
    cond do
      p1 != p2 -> p1 <= p2
      Decimal.compare(a1, a2) != :eq -> Decimal.compare(a1, a2) == :lt
      true -> i1 <= i2
    end
  end

  defp incentives(slab_id) do
    TenantRepo.all(
      from(i in "m_savings_interest_incentives",
        where: i.deposit_account_interest_rate_slab_id == ^slab_id,
        order_by: i.id,
        select: %{id: i.id}
      )
    )
  end
end
