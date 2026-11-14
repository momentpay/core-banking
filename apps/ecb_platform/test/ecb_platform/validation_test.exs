defmodule ECBPlatform.ValidationTest do
  use ExUnit.Case, async: true

  alias ECBPlatform.Errors
  alias ECBPlatform.Errors.PlatformApiDataValidation
  alias ECBPlatform.Validation

  defp codes(validation), do: validation.errors |> Enum.reverse() |> Enum.map(& &1.code)

  test "a missing mandatory value is reported with Fineract's code and an empty argument" do
    v = Validation.new("office") |> Validation.param("name", nil) |> Validation.not_blank()

    assert [
             %{
               code: "validation.msg.office.name.cannot.be.blank",
               default_message: "The parameter `name` is mandatory.",
               parameter: "name",
               args: [nil]
             }
           ] = v.errors
  end

  test "blank text counts as missing" do
    assert Validation.new("x")
           |> Validation.param("a", "  ")
           |> Validation.not_blank()
           |> Validation.errors?()
  end

  test "ignore_if_null skips an optional value that is absent but still checks one that is given" do
    absent =
      Validation.new("x")
      |> Validation.param("a", nil)
      |> Validation.ignore_if_null()
      |> Validation.not_blank()

    refute Validation.errors?(absent)

    given =
      Validation.new("x")
      |> Validation.param("a", "")
      |> Validation.ignore_if_null()
      |> Validation.not_blank()

    assert Validation.errors?(given)
  end

  test "length is measured after trimming, and the error carries the limit and the value" do
    ok = Validation.new("x") |> Validation.param("a", "  abc  ") |> Validation.max_length(3)
    refute Validation.errors?(ok)

    v = Validation.new("x") |> Validation.param("a", "abcd") |> Validation.max_length(3)
    assert [%{code: "validation.msg.x.a.exceeds.max.length", args: [3, "abcd"]}] = v.errors
  end

  test "whole numbers" do
    v = Validation.new("x") |> Validation.param("a", 0) |> Validation.greater_than_zero()
    assert [%{code: "validation.msg.x.a.not.greater.than.zero", args: [0, 0]}] = v.errors

    ok = Validation.new("x") |> Validation.param("a", 1) |> Validation.greater_than_zero()
    refute Validation.errors?(ok)

    v = Validation.new("x") |> Validation.param("a", -1) |> Validation.zero_or_greater()
    assert [%{code: "validation.msg.x.a.not.zero.or.greater"}] = v.errors

    v = Validation.new("x") |> Validation.param("a", 9) |> Validation.in_range(1, 5)
    assert [%{code: "validation.msg.x.a.is.not.within.expected.range"}] = v.errors
  end

  test "a value must be one of the allowed ones" do
    v = Validation.new("x") |> Validation.param("a", "z") |> Validation.one_of(["a", "b"])
    assert [%{code: "validation.msg.x.a.is.not.one.of.expected.enumerations"}] = v.errors
  end

  test "dates can be bounded" do
    v =
      Validation.new("x")
      |> Validation.param("d", ~D[2020-01-01])
      |> Validation.date_not_before(~D[2020-02-01])

    assert codes(v) == ["validation.msg.x.d.is.before.than.date"]

    v =
      Validation.new("x")
      |> Validation.param("d", ~D[2020-03-01])
      |> Validation.date_not_after(~D[2020-02-01])

    assert codes(v) == ["validation.msg.x.d.is.greater.than.date"]
  end

  test "every problem is collected, in the order found" do
    v =
      Validation.new("office")
      |> Validation.param("name", nil)
      |> Validation.not_blank()
      |> Validation.param("openingDate", nil)
      |> Validation.not_null()

    assert codes(v) == [
             "validation.msg.office.name.cannot.be.blank",
             "validation.msg.office.openingDate.cannot.be.blank"
           ]

    error = assert_raise PlatformApiDataValidation, fn -> Validation.raise_if_errors!(v) end
    assert Enum.map(error.errors, & &1.parameter) == ["name", "openingDate"]
  end

  test "nothing wrong means no error is raised" do
    assert :ok =
             Validation.new("x")
             |> Validation.param("a", "fine")
             |> Validation.not_blank()
             |> Validation.raise_if_errors!()
  end

  describe "the response" do
    test "a validation error is HTTP 400 in Fineract's shape; a missing value's argument is an empty object" do
      v = Validation.new("office") |> Validation.param("name", nil) |> Validation.not_blank()
      {400, body} = Errors.to_api(%PlatformApiDataValidation{errors: v.errors})

      assert body["userMessageGlobalisationCode"] == "validation.msg.validation.errors.exist"
      assert body["httpStatusCode"] == "400"
      assert [%{"parameterName" => "name", "args" => [%{}]}] = body["errors"]
    end

    test "data integrity and domain rule errors are HTTP 403 with their own codes" do
      {403, integrity} =
        Errors.to_api(%Errors.DataIntegrity{
          code: "error.msg.x.duplicate",
          message: "dup",
          parameter: "name",
          args: ["n"]
        })

      assert integrity["userMessageGlobalisationCode"] == "error.msg.x.duplicate"
      assert [%{"parameterName" => "name", "args" => [%{"value" => "n"}]}] = integrity["errors"]

      {403, rule} =
        Errors.to_api(%Errors.DomainRuleViolation{code: "error.msg.x.rule", message: "no"})

      assert rule["userMessageGlobalisationCode"] == "validation.msg.domain.rule.violation"
    end

    test "other exceptions are not ours to describe" do
      assert Errors.to_api(%RuntimeError{}) == nil
    end
  end
end
