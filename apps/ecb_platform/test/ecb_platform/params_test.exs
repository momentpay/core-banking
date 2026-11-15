defmodule ECBPlatform.ParamsTest do
  use ExUnit.Case, async: true

  alias ECBPlatform.Errors.{InvalidJson, PlatformApiDataValidation, UnsupportedParameter}
  alias ECBPlatform.Params
  alias ECBPlatform.Params.DatePattern

  defp params(map), do: Params.parse!(Jason.encode!(map))

  describe "parse!/1" do
    test "a missing or blank body is invalid" do
      assert_raise InvalidJson, fn -> Params.parse!(nil) end
      assert_raise InvalidJson, fn -> Params.parse!("") end
      assert_raise InvalidJson, fn -> Params.parse!("   ") end
    end

    test "text that is not JSON, or not an object, is invalid" do
      assert_raise InvalidJson, fn -> Params.parse!("{bad") end
      assert_raise InvalidJson, fn -> Params.parse!("[1]") end
    end
  end

  describe "check_supported!/2" do
    test "names every parameter that is not known, sorted" do
      error =
        assert_raise UnsupportedParameter, fn ->
          Params.check_supported!(params(%{"b" => 1, "name" => "x", "a" => 2}), ["name"])
        end

      assert error.parameters == ["a", "b"]
    end
  end

  describe "reading values" do
    test "exists? is about the key, has_value? about a real value" do
      p = params(%{"a" => nil, "b" => "", "c" => "x", "d" => 0})

      assert Params.exists?(p, "a") and Params.exists?(p, "b")
      refute Params.exists?(p, "z")
      refute Params.has_value?(p, "a")
      refute Params.has_value?(p, "b")
      assert Params.has_value?(p, "c") and Params.has_value?(p, "d")
    end

    test "string/2 treats blank as no value, command_string/2 as empty text" do
      p = params(%{"a" => "  ", "b" => "x", "n" => 5})

      assert Params.string(p, "a") == nil
      assert Params.command_string(p, "a") == ""
      assert Params.string(p, "b") == "x"
      assert Params.string(p, "n") == "5"
      assert Params.string(p, "missing") == nil
    end

    test "long/2 reads numbers and numeric text, and refuses anything else" do
      p = params(%{"a" => 7, "b" => "8", "c" => "x"})

      assert Params.long(p, "a") == 7
      assert Params.long(p, "b") == 8
      assert Params.long(p, "none") == nil
      assert_raise ECBPlatform.Errors.InvalidNumber, fn -> Params.long(p, "c") end
    end

    test "text that is not a number is answered as Fineract answers it, without an envelope" do
      error =
        assert_raise ECBPlatform.Errors.InvalidNumber, fn ->
          Params.long(params(%{"a" => "abc"}), "a")
        end

      assert {400, body} = ECBPlatform.Errors.to_api(error)
      assert body["userMessageGlobalisationCode"] == "validation.msg.invalid.decimal.format"
      assert body["parameterName"] == "a"
      assert body["value"] == "abc"
      assert body["args"] == []
      refute Map.has_key?(body, "errors")
    end

    test "boolean/2 reads text as Fineract does: only true, in any case, is true" do
      p = params(%{"a" => true, "b" => "false", "c" => "maybe", "d" => "TRUE", "e" => nil})
      assert Params.boolean(p, "a") == true
      assert Params.boolean(p, "b") == false
      assert Params.boolean(p, "c") == false
      assert Params.boolean(p, "d") == true
      assert Params.boolean(p, "e") == nil
      assert Params.boolean(p, "absent") == nil
    end

    test "strict_boolean/2 refuses anything that is not true or false" do
      p = params(%{"a" => true, "b" => "maybe"})
      assert Params.strict_boolean(p, "a") == true
      assert Params.strict_boolean(p, "absent") == nil
      assert_raise ECBPlatform.Errors.InvalidJsonData, fn -> Params.strict_boolean(p, "b") end
    end

    test "integer/2 refuses text that is not a whole number, showing the value" do
      p = params(%{"a" => 7, "b" => "x"})
      assert Params.integer(p, "a") == 7
      assert Params.integer(p, "absent") == nil

      error = assert_raise PlatformApiDataValidation, fn -> Params.integer(p, "b") end
      assert [%{code: "validation.msg.invalid.integer", value: "x", args: ["x"]}] = error.errors
    end

    test "decimal/2 reads JSON numbers exactly and formatted text" do
      p = Params.parse!(~s({"a": 12.50, "b": "1,234.5", "c": 3}))
      assert Decimal.equal?(Params.decimal(p, "a"), Decimal.new("12.5"))
      assert Decimal.equal?(Params.decimal(p, "b"), Decimal.new("1234.5"))
      assert Decimal.equal?(Params.decimal(p, "c"), Decimal.new(3))
    end
  end

  describe "date/2" do
    test "reads a date written to the given format" do
      p = params(%{"d" => "01 March 2020", "dateFormat" => "dd MMMM yyyy", "locale" => "en"})
      assert Params.date(p, "d") == ~D[2020-03-01]
    end

    test "needs the date format and the locale to be sent" do
      error =
        assert_raise PlatformApiDataValidation, fn ->
          Params.date(params(%{"d" => "01 March 2020"}), "d")
        end

      assert Enum.map(error.errors, & &1.code) == [
               "validation.msg.missing.dateFormat.parameter",
               "validation.msg.missing.locale.parameter"
             ]
    end

    test "a value that does not fit the format is reported with the format" do
      p = params(%{"d" => "2020-03-01", "dateFormat" => "dd MMMM yyyy", "locale" => "en"})
      error = assert_raise PlatformApiDataValidation, fn -> Params.date(p, "d") end

      assert [
               %{
                 code: "validation.msg.invalid.dateFormat.format",
                 parameter: "d",
                 args: [nil, "dd MMMM yyyy"]
               }
             ] = error.errors
    end

    test "a blank locale is refused" do
      p = params(%{"d" => "01 March 2020", "dateFormat" => "dd MMMM yyyy", "locale" => ""})
      assert_raise PlatformApiDataValidation, fn -> Params.date(p, "d") end
    end

    test "an absent or blank date is nil without needing a format" do
      assert Params.date(params(%{}), "d") == nil
      assert Params.date(params(%{"d" => ""}), "d") == nil
    end
  end

  describe "change detection" do
    test "only a parameter that is present can be a change" do
      p = params(%{"name" => "New"})
      assert Params.changed_string?(p, "name", "Old")
      refute Params.changed_string?(p, "name", "New")
      refute Params.changed_string?(p, "other", "Old")
    end

    test "clearing a field that was empty is still a change, as in Fineract" do
      p = params(%{"externalId" => ""})
      assert Params.changed_string?(p, "externalId", nil)
      refute Params.changed_string?(p, "externalId", "")
    end

    test "numbers, dates and booleans" do
      p =
        params(%{
          "n" => 2,
          "b" => true,
          "d" => "01 March 2020",
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        })

      assert Params.changed_long?(p, "n", 1)
      refute Params.changed_long?(p, "n", 2)
      assert Params.changed_boolean?(p, "b", false)
      refute Params.changed_boolean?(p, "b", true)
      assert Params.changed_date?(p, "d", ~D[2020-03-02])
      refute Params.changed_date?(p, "d", ~D[2020-03-01])
    end
  end

  describe "DatePattern.parse/2" do
    test "the patterns clients use" do
      assert DatePattern.parse("01 March 2020", "dd MMMM yyyy") == {:ok, ~D[2020-03-01]}
      assert DatePattern.parse("1 March 2020", "dd MMMM yyyy") == {:ok, ~D[2020-03-01]}
      assert DatePattern.parse("01 Mar 2020", "dd MMM yyyy") == {:ok, ~D[2020-03-01]}
      assert DatePattern.parse("2020-03-01", "yyyy-MM-dd") == {:ok, ~D[2020-03-01]}
      assert DatePattern.parse("01/03/20", "dd/MM/yy") == {:ok, ~D[2020-03-01]}
      assert DatePattern.parse("1/3/2020", "d/M/yyyy") == {:ok, ~D[2020-03-01]}
    end

    test "case does not matter and a month may be written in full or abbreviated" do
      assert DatePattern.parse("01 MARCH 2020", "dd MMM yyyy") == {:ok, ~D[2020-03-01]}
      assert DatePattern.parse("01 mar 2020", "dd MMMM yyyy") == {:ok, ~D[2020-03-01]}
    end

    test "a time of day after the date is accepted and ignored" do
      assert DatePattern.parse("01 March 2020 10:11:12", "dd MMMM yyyy") == {:ok, ~D[2020-03-01]}
    end

    test "the date is checked strictly" do
      assert DatePattern.parse("29 February 2021", "dd MMMM yyyy") == :error
      assert DatePattern.parse("29 February 2020", "dd MMMM yyyy") == {:ok, ~D[2020-02-29]}
      assert DatePattern.parse("31 April 2020", "dd MMMM yyyy") == :error
    end

    test "text that does not fit is an error" do
      assert DatePattern.parse("March 1 2020", "dd MMMM yyyy") == :error
      assert DatePattern.parse("01 Sept 2020", "dd MMM yyyy") == :error
      assert DatePattern.parse("", "dd MMMM yyyy") == :error
    end

    test "a pattern with letters that are not understood never matches" do
      assert DatePattern.parse("Sunday 01 March 2020", "EEEE dd MMMM yyyy") == :error
    end

    test "quoted text in a pattern is literal" do
      assert DatePattern.parse("01 of March 2020", "dd 'of' MMMM yyyy") == {:ok, ~D[2020-03-01]}
    end
  end
end
