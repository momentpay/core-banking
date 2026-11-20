defmodule ECBDeposits.Savings.ChargesTest do
  use ExUnit.Case, async: true

  alias ECBDeposits.Savings.Charges

  defp d(text), do: Date.from_iso8601!(text)

  defp fee(time, attrs),
    do:
      Map.merge(
        %{time: time, fee_on_month: nil, fee_on_day: nil, fee_interval: nil, due_date: nil},
        attrs
      )

  describe "when a recurring charge falls due" do
    test "an annual fee falls due on its day of the year, the first one not before the start" do
      c = fee(6, %{fee_on_month: 6, fee_on_day: 15})
      assert Charges.next_due_from(c, d("2024-03-01")) == d("2024-06-15")
      assert Charges.next_due_from(c, d("2024-06-15")) == d("2024-06-15")
      assert Charges.next_due_from(c, d("2024-06-16")) == d("2025-06-15")
      assert Charges.next(c, d("2024-06-15")) == d("2025-06-15")
    end

    test "a monthly fee keeps its day, as far as the month allows" do
      c = fee(7, %{fee_on_month: 1, fee_on_day: 31, fee_interval: 1})
      assert Charges.next(c, d("2024-01-31")) == d("2024-02-29")
      assert Charges.next(c, d("2024-02-29")) == d("2024-03-31")
      assert Charges.previous(c, d("2024-03-31")) == d("2024-02-29")
    end

    test "a weekly fee keeps its day of the week" do
      c = fee(11, %{fee_on_day: 1, fee_interval: 2, due_date: d("2024-03-04")})
      assert Charges.next(c, d("2024-03-04")) == d("2024-03-18")
      assert Charges.next_due_from(c, d("2024-03-10")) == d("2024-03-18")
    end
  end

  describe "what paying and waiving leave of a charge" do
    defp open_charge(extra \\ %{}) do
      Map.merge(
        fee(2, %{
          amount: Decimal.new(10),
          paid: nil,
          waived_amount: nil,
          written_off: nil,
          outstanding: Decimal.new(10),
          is_paid: false,
          waived: false,
          is_active: true
        }),
        extra
      )
    end

    test "a payment lowers what is outstanding and the charge is paid when nothing is" do
      part = Charges.after_payment(open_charge(), Decimal.new(4))
      assert Decimal.eq?(part.outstanding, 6)
      assert Decimal.eq?(part.paid, 4)
      refute part.is_paid

      done = Charges.after_payment(part, Decimal.new(6))
      assert Decimal.eq?(done.outstanding, 0)
      assert done.is_paid
    end

    test "a recurring charge paid up is outstanding in full for its next day" do
      c =
        open_charge(%{
          time: 7,
          fee_on_month: 1,
          fee_on_day: 20,
          fee_interval: 1,
          due_date: d("2024-03-20")
        })

      paid = Charges.after_payment(c, Decimal.new(10))
      assert paid.due_date == d("2024-04-20")
      assert Decimal.eq?(paid.outstanding, 10)
      refute paid.is_paid
    end

    test "a waiver takes what is outstanding and undoing it gives it back" do
      waived = Charges.after_waiver(open_charge())
      assert waived.waived
      assert Decimal.eq?(waived.outstanding, 0)
      assert Decimal.eq?(waived.waived_amount, 10)

      back = Charges.after_undone_waiver(waived, Decimal.new(10))
      refute back.waived
      assert Decimal.eq?(back.outstanding, 10)
    end

    test "a withdrawal fee follows what the withdrawal was" do
      flat = %{calculation: 1, amount: Decimal.new("2.5"), percentage: nil}
      pct = %{calculation: 2, amount: Decimal.new(0), percentage: Decimal.new("1.5")}

      assert Decimal.eq?(
               Charges.withdrawal_fee_amount(flat, Decimal.new(100), 2),
               Decimal.new("2.50")
             )

      assert Decimal.eq?(
               Charges.withdrawal_fee_amount(pct, Decimal.new(50), 2),
               Decimal.new("0.75")
             )
    end
  end
end
