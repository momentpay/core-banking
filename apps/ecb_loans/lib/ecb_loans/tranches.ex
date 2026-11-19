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

  @doc "The tranches of a loan that are still to be paid out, in the order they are expected."
  @spec pending(integer) :: [map]
  def pending(loan_id), do: loan_id |> list() |> Enum.filter(&is_nil(&1.disbursed_on))

  @doc """
  The tranches the next disbursement pays out: those still to be paid that are expected on the earliest date
  (Fineract's `fetchUndisbursedDetail`).
  """
  @spec next_due(integer) :: [map]
  def next_due(loan_id) do
    case pending(loan_id) do
      [] -> []
      [first | _] = pending -> Enum.filter(pending, &(&1.expected_date == first.expected_date))
    end
  end

  @doc "Marks tranches `ids` as paid out on `on`."
  @spec pay!([integer], Date.t()) :: :ok
  def pay!([], _on), do: :ok

  def pay!(ids, on) do
    TenantRepo.update_all(from(d in "m_loan_disbursement_detail", where: d.id in ^ids),
      set: [disbursedon_date: on]
    )

    :ok
  end

  @doc "Whether a tranche of the loan has been taken back (the last disbursal was undone)."
  @spec reversed?(integer) :: boolean
  def reversed?(loan_id),
    do:
      TenantRepo.exists?(
        from(d in "m_loan_disbursement_detail", where: d.loan_id == ^loan_id and d.is_reversed)
      )

  @doc "Takes tranche `id` back: it no longer counts and is not paid out."
  @spec reverse!(integer) :: :ok
  def reverse!(id) do
    TenantRepo.update_all(from(d in "m_loan_disbursement_detail", where: d.id == ^id),
      set: [disbursedon_date: nil, is_reversed: true]
    )

    :ok
  end

  @doc """
  Makes every tranche of the loan one that is still to be paid out (the disbursal was undone); what the loan pays
  out is the approved principal again. Nothing happens for a loan that is not paid out in tranches.
  """
  @spec unpay_all!(integer, Decimal.t()) :: :ok
  def unpay_all!(loan_id, approved) do
    if any?(loan_id) do
      TenantRepo.update_all(from(d in "m_loan_disbursement_detail", where: d.loan_id == ^loan_id),
        set: [disbursedon_date: nil]
      )

      TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan_id),
        set: [net_disbursal_amount: approved]
      )
    end

    :ok
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
  def guard!(loan_id, what), do: if(any?(loan_id), do: unsupported!(what), else: :ok)

  @doc "Refuses `what` as not built yet for a loan that is paid out in tranches."
  @spec unsupported!(String.t()) :: no_return
  def unsupported!(what) do
    raise ECBPlatform.Errors.DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message:
        "Not supported yet by E-CoreBank for a loan that is paid out in tranches: " <> what,
      args: [what]
  end
end
