defmodule ECBPlatform.RecurrenceRuleTest do
  use ExUnit.Case, async: true

  alias ECBPlatform.RecurrenceRule

  describe "validate/1" do
    test "accepts the rules the working week uses" do
      assert RecurrenceRule.validate("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR") == :ok
      assert RecurrenceRule.validate("FREQ=DAILY") == :ok
      assert RecurrenceRule.validate("FREQ=MONTHLY;INTERVAL=2;BYDAY=1MO") == :ok
    end

    test "refuses text that is not a rule" do
      assert {:error, :parse, _} = RecurrenceRule.validate("not a rule")
      assert {:error, :parse, _} = RecurrenceRule.validate("")
      assert {:error, :parse, _} = RecurrenceRule.validate("FREQ=NEVER")
      assert {:error, :parse, _} = RecurrenceRule.validate("FREQ=WEEKLY;BYDAY=XX")
      assert {:error, :parse, _} = RecurrenceRule.validate("FREQ=WEEKLY;INTERVAL=0")
      assert {:error, :parse, _} = RecurrenceRule.validate("FREQ=WEEKLY;COLOUR=RED")
    end

    test "a rule without a frequency reads but is not usable" do
      assert RecurrenceRule.validate("INTERVAL=1;BYDAY=MO") == {:error, :invalid}
    end
  end

  describe "working_day?/2" do
    test "follows the weekdays the rule names" do
      rule = "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR"
      assert RecurrenceRule.working_day?(rule, ~D[2026-11-13])
      refute RecurrenceRule.working_day?(rule, ~D[2026-11-14])
      refute RecurrenceRule.working_day?(rule, ~D[2026-11-15])
      assert RecurrenceRule.working_day?(rule, ~D[2026-11-16])
    end

    test "every day is a working day when the rule names none" do
      assert RecurrenceRule.working_day?("FREQ=DAILY", ~D[2026-11-15])
    end
  end
end
