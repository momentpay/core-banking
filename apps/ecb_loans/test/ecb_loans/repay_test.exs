defmodule ECBLoans.RepayTest do
  use ExUnit.Case, async: true

  alias ECBLoans.Loans.Repay

  defp d(text), do: Decimal.new(text)

  defp installment(id, due, principal, interest, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        due_date: due,
        completed: false,
        principal: d(principal),
        principal_completed: nil,
        principal_writtenoff: nil,
        interest: d(interest),
        interest_completed: nil,
        interest_writtenoff: nil,
        interest_waived: nil,
        fee_charges: nil,
        fee_charges_completed: nil,
        fee_charges_writtenoff: nil,
        fee_charges_waived: nil,
        penalty_charges: nil,
        penalty_charges_completed: nil,
        penalty_charges_writtenoff: nil,
        penalty_charges_waived: nil
      },
      extra
    )
  end

  test "money pays interest before principal, installment by installment" do
    rows = [
      installment(1, ~D[2024-04-01], "788.49", "100.00"),
      installment(2, ~D[2024-05-01], "796.37", "92.12")
    ]

    {touched, left, portions} = Repay.allocate(rows, ~D[2024-04-01], d("1000"))

    assert Enum.map(touched, & &1.id) == [1, 2]
    assert Decimal.eq?(left, 0)
    assert Decimal.eq?(portions.interest, d("192.12"))
    assert Decimal.eq?(portions.principal, d("807.88"))
  end

  test "what is left once everything is paid is an overpayment" do
    rows = [installment(1, ~D[2024-04-01], "100", "10")]
    {_touched, left, portions} = Repay.allocate(rows, ~D[2024-04-01], d("150"))

    assert Decimal.eq?(left, d("40"))
    assert Decimal.eq?(portions.principal, d("100"))
  end

  test "an installment that is complete is skipped, and part paid ones start from what is owed" do
    rows = [
      installment(1, ~D[2024-04-01], "100", "10", %{completed: true}),
      installment(2, ~D[2024-05-01], "100", "10", %{
        interest_completed: d("10"),
        principal_completed: d("60")
      })
    ]

    {touched, left, portions} = Repay.allocate(rows, ~D[2024-05-01], d("30"))

    assert Enum.map(touched, & &1.id) == [2]
    assert Decimal.eq?(portions.principal, d("30"))
    assert Decimal.eq?(left, 0)
  end
end
