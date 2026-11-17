defmodule ECBPlatform.CronTest do
  use ExUnit.Case, async: true

  alias ECBPlatform.Cron

  defp next(expression, from), do: Cron.next(expression, from)

  test "the expressions of the jobs Fineract ships with are read" do
    for expression <- [
          "0 1 0 1/1 * ? *",
          "0 0 12 * * ?",
          "0 0/15 * * * ?",
          "0 0/1 * * *  ?",
          "0 20 22 1/1 * ? *",
          "0 0 5 1/1 * ? *"
        ] do
      assert Cron.valid?(expression), expression
    end
  end

  test "a daily job fires at its time, today when that is still to come and tomorrow when it has gone" do
    assert next("0 1 0 1/1 * ? *", ~N[2024-05-01 12:00:00]) == ~N[2024-05-02 00:01:00]
    assert next("0 1 0 1/1 * ? *", ~N[2024-05-01 00:00:30]) == ~N[2024-05-01 00:01:00]
    # at the very time it fired, the next firing is the day after
    assert next("0 1 0 1/1 * ? *", ~N[2024-05-01 00:01:00]) == ~N[2024-05-02 00:01:00]
  end

  test "steps count from their start" do
    assert next("0 0/15 * * * ?", ~N[2024-05-01 10:07:00]) == ~N[2024-05-01 10:15:00]
    assert next("0 0/15 * * * ?", ~N[2024-05-01 10:45:00]) == ~N[2024-05-01 11:00:00]
    assert next("0 5/20 * * * ?", ~N[2024-05-01 10:30:00]) == ~N[2024-05-01 10:45:00]
  end

  test "months, days of the week, lists and ranges" do
    # 1 May 2024 is a Wednesday; weekdays count from Sunday = 1, so MON-FRI is 2-6
    assert next("0 0 9 ? * MON-FRI", ~N[2024-05-03 10:00:00]) == ~N[2024-05-06 09:00:00]
    assert next("0 0 9 ? * 2-6", ~N[2024-05-03 10:00:00]) == ~N[2024-05-06 09:00:00]
    assert next("0 30 6 1,15 * ?", ~N[2024-05-02 00:00:00]) == ~N[2024-05-15 06:30:00]
    assert next("0 0 0 1 JAN,JUL ?", ~N[2024-05-02 00:00:00]) == ~N[2024-07-01 00:00:00]
    assert next("0 0 0 29 2 ? *", ~N[2024-05-02 00:00:00]) == ~N[2028-02-29 00:00:00]
  end

  test "the year field limits the firing, and a time that cannot come gives nil" do
    assert next("0 0 0 1 1 ? 2030", ~N[2024-05-02 00:00:00]) == ~N[2030-01-01 00:00:00]
    assert next("0 0 0 1 1 ? 2020", ~N[2024-05-02 00:00:00]) == nil
  end

  test "an expression that cannot be read is refused" do
    for expression <- [
          "",
          "0 0 0 * *",
          "0 0 24 * * ?",
          "0 61 0 * * ?",
          "0 0 0 L * ?",
          "0 0 0 * * 6#3",
          "a b c d e f"
        ] do
      refute Cron.valid?(expression), expression
    end
  end
end
