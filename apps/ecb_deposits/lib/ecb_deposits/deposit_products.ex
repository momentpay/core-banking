defmodule ECBDeposits.DepositProducts do
  @moduledoc """
  Fixed and recurring deposit products, the read side, after Fineract's `DepositProductReadPlatformServiceImpl`. A
  deposit product is a savings product (`m_savings_product`, deposit type 200 or 300) that also has a term and a
  pre-closure penalty (`m_deposit_product_term_and_preclosure`), for a recurring deposit the rules of its
  installments (`m_deposit_product_recurring_detail`), and interest rate charts. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.{DepositEnums, InterestCharts, SavingsProducts}
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "The deposit type of a kind of product."
  @spec type(:fixed | :recurring) :: integer
  def type(:fixed), do: DepositEnums.fixed()
  def type(:recurring), do: DepositEnums.recurring()

  @doc "Every product of the kind, by id."
  @spec list(:fixed | :recurring) :: [map]
  def list(kind) do
    products = kind |> type() |> SavingsProducts.list()
    ids = Enum.map(products, & &1.id)
    terms = terms(ids)
    recurring = if kind == :recurring, do: recurring(ids), else: %{}

    Enum.map(products, &Map.merge(&1, details(&1.id, terms, recurring)))
  end

  @doc "One product of the kind, or `{:error, ResourceNotFound}`."
  @spec get(:fixed | :recurring, integer) :: {:ok, map} | {:error, Exception.t()}
  def get(kind, id) do
    case SavingsProducts.get(type(kind), id) do
      {:ok, product} ->
        recurring = if kind == :recurring, do: recurring([id]), else: %{}
        {:ok, Map.merge(product, details(id, terms([id]), recurring))}

      {:error, _} ->
        # Fineract's read of a recurring deposit product answers with the words of the fixed deposit's
        {:error, not_found(:fixed, id)}
    end
  end

  @doc "Like `get/2` but raises the not-found error."
  @spec fetch!(:fixed | :recurring, integer) :: map
  def fetch!(kind, id) do
    case get(kind, id) do
      {:ok, product} -> product
      {:error, error} -> raise error
    end
  end

  @doc """
  The deposit types that can be changed or deleted through the endpoints of a kind: Fineract's fixed deposit
  endpoints also reach recurring deposit products, but not the other way round.
  """
  @spec manageable_types(:fixed | :recurring) :: [integer]
  def manageable_types(:fixed), do: [type(:fixed), type(:recurring)]
  def manageable_types(:recurring), do: [type(:recurring)]

  @doc "Whether a product the endpoints of the kind can change or delete exists."
  @spec exists?(:fixed | :recurring, integer) :: boolean
  def exists?(kind, id) do
    types = manageable_types(kind)

    TenantRepo.exists?(
      from(sp in "m_savings_product", where: sp.id == ^id and sp.deposit_type_enum in ^types)
    )
  end

  @doc "The error for a product that does not exist."
  @spec not_found(:fixed | :recurring, integer) :: Exception.t()
  def not_found(:fixed, id),
    do:
      ResourceNotFound.new(
        "error.msg.fixeddepositproduct.id.invalid",
        "Fixed deposit product with identifier #{id} does not exist",
        [id]
      )

  def not_found(:recurring, id),
    do:
      ResourceNotFound.new(
        "error.msg.recurringdepositproduct.id.invalid",
        "Recurring deposit product with identifier #{id} does not exist",
        [id]
      )

  @doc "The interest rate charts of a product."
  @spec charts(integer) :: [map]
  def charts(id), do: InterestCharts.for_product(id)

  defp details(id, terms, recurring) do
    term = Map.get(terms, id, %{})
    Map.merge(term, Map.get(recurring, id, %{}))
  end

  defp terms(ids) do
    from(t in "m_deposit_product_term_and_preclosure",
      where: t.savings_product_id in ^ids,
      select: %{
        id: t.savings_product_id,
        pre_closure_penal_applicable: t.pre_closure_penal_applicable,
        pre_closure_penal_interest: t.pre_closure_penal_interest,
        pre_closure_penal_interest_on: t.pre_closure_penal_interest_on_enum,
        min_deposit_term: t.min_deposit_term,
        max_deposit_term: t.max_deposit_term,
        min_deposit_term_type: t.min_deposit_term_type_enum,
        max_deposit_term_type: t.max_deposit_term_type_enum,
        in_multiples_of_deposit_term: t.in_multiples_of_deposit_term,
        in_multiples_of_deposit_term_type: t.in_multiples_of_deposit_term_type_enum,
        min_deposit_amount: t.min_deposit_amount,
        deposit_amount: t.deposit_amount,
        max_deposit_amount: t.max_deposit_amount
      }
    )
    |> TenantRepo.all()
    |> Map.new(&{&1.id, Map.delete(&1, :id)})
  end

  defp recurring(ids) do
    from(r in "m_deposit_product_recurring_detail",
      where: r.savings_product_id in ^ids,
      select: %{
        id: r.savings_product_id,
        is_mandatory: r.is_mandatory,
        allow_withdrawal: r.allow_withdrawal,
        adjust_advance_towards_future_payments: r.adjust_advance_towards_future_payments
      }
    )
    |> TenantRepo.all()
    |> Map.new(&{&1.id, Map.delete(&1, :id)})
  end
end
