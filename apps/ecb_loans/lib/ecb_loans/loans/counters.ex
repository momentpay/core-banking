defmodule ECBLoans.Loans.Counters do
  @moduledoc """
  The count a loan has among its client's loans of the same product (`loanProductCounter`), kept as Fineract
  keeps it (`LoanWritePlatformServiceJpaRepositoryImpl.updateLoanCounters` and `removeLoanCycle`):

    * a loan paid out takes the next number, or the place of the first loan the client had paid out on a later
      date, which and every later one move up by one;
    * a loan whose payout is undone, or that is written off, gives up its number and the loans of the product
      with a higher one move down by one (a loan written off then takes the next number again).

  This is for products that are not part of the borrower cycle; those have a client-wide counter as well,
  which E-CoreBank does not keep yet.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Gives the loan, paid out on `date`, its number."
  @spec assign!(map, Date.t()) :: :ok
  def assign!(loan, date) do
    later =
      TenantRepo.all(
        from(l in "m_loan",
          where:
            l.client_id == ^loan.client_id and not is_nil(l.disbursedon_date) and
              l.disbursedon_date > ^date,
          order_by: [l.disbursedon_date, l.id],
          select: %{id: l.id, product_id: l.product_id, counter: l.loan_product_counter}
        )
      )

    highest =
      TenantRepo.one(
        from(l in "m_loan",
          where: l.client_id == ^loan.client_id and l.product_id == ^loan.product_id,
          select: max(l.loan_product_counter)
        )
      )

    number =
      Enum.reduce(later, (highest || 0) + 1, fn other, number ->
        if other.product_id == loan.product_id, do: move_up(other, number), else: number
      end)

    set!(loan.id, number)
  end

  defp move_up(other, number) do
    counter = other.counter || 0
    set!(other.id, counter + 1)
    min(number, counter)
  end

  @doc "Takes the number of the loan back; the loans of its product with a higher number move down."
  @spec remove!(map) :: :ok
  def remove!(loan) do
    number =
      TenantRepo.one(from(l in "m_loan", where: l.id == ^loan.id, select: l.loan_product_counter))

    if number do
      TenantRepo.all(
        from(l in "m_loan",
          where:
            l.client_id == ^loan.client_id and l.product_id == ^loan.product_id and
              l.loan_product_counter > ^number and is_nil(l.loan_counter),
          order_by: l.loan_product_counter,
          select: %{id: l.id, counter: l.loan_product_counter}
        )
      )
      |> Enum.each(&set!(&1.id, &1.counter - 1))
    end

    set!(loan.id, nil)
  end

  defp set!(id, number) do
    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [loan_product_counter: number]
    )

    :ok
  end
end
