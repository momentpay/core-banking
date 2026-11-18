defmodule ECBLoans.Tranches do
  @moduledoc """
  The tranches a loan is paid out in (`m_loan_disbursement_detail`): the date each is expected, its principal, and
  once it is paid out the date it was. A loan on a product that does not pay out in tranches has none.
  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Stores the tranches of a loan, in the order given."
  @spec store!(integer, [%{date: Date.t(), amount: ECBMoney.t()}]) :: :ok
  def store!(_loan_id, []), do: :ok

  def store!(loan_id, tranches) do
    rows =
      for t <- tranches do
        %{
          loan_id: loan_id,
          expected_disburse_date: t.date,
          principal: ECBMoney.amount(t.amount),
          is_reversed: false
        }
      end

    TenantRepo.insert_all("m_loan_disbursement_detail", rows)
    :ok
  end

  @doc "The tranches of a loan that stand, by expected date, as maps."
  @spec list(integer) :: [map]
  def list(loan_id) do
    from(d in "m_loan_disbursement_detail",
      where: d.loan_id == ^loan_id and d.is_reversed == false,
      order_by: [d.expected_disburse_date, d.id],
      select: %{
        id: d.id,
        loan_id: d.loan_id,
        expected_date: d.expected_disburse_date,
        disbursed_on: d.disbursedon_date,
        principal: d.principal,
        net_disbursal_amount: d.net_disbursal_amount
      }
    )
    |> TenantRepo.all()
  end

  @doc "Whether the loan is paid out in tranches (it has some stored)."
  @spec any?(integer) :: boolean
  def any?(loan_id),
    do: TenantRepo.exists?(from(d in "m_loan_disbursement_detail", where: d.loan_id == ^loan_id))

  @doc """
  Refuses what is not built yet for a loan that is paid out in tranches: `what` is said in the error. Nothing
  happens for a loan that is not.
  """
  @spec guard!(integer, String.t()) :: :ok
  def guard!(loan_id, what) do
    if any?(loan_id) do
      raise ECBPlatform.Errors.DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Not supported yet by E-CoreBank for a loan that is paid out in tranches: " <> what,
        args: [what]
    else
      :ok
    end
  end
end
