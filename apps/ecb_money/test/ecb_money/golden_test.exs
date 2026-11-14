defmodule ECBMoney.GoldenTest do
  @moduledoc """
  Golden master: every case in the fixture was produced by running Apache Fineract's own
  `org.apache.fineract.organisation.monetary.domain.Money` (see `parity/scripts/gen-money-golden.sh`).
  Each case is replayed here and must give exactly the same text.

  This is what keeps `ECBMoney` honest: the other tests show it behaves as we read the Java, this one
  shows it behaves as the Java does.
  """
  use ExUnit.Case, async: true

  alias ECBMoney.{Context, Currency, Rounding}

  @fixture Path.expand("../fixtures/fineract_money_golden.json.gz", __DIR__)

  # Loaded when the tests run, not at compile time: decoding 130,000 cases into a module attribute
  # makes compilation very slow.
  setup_all do
    cases = @fixture |> File.read!() |> :zlib.gunzip() |> Jason.decode!()
    {:ok, cases: cases}
  end

  test "the fixture is present and large enough to mean something", %{cases: cases} do
    assert length(cases) > 100_000
    ops = cases |> Enum.map(& &1["op"]) |> Enum.uniq() |> Enum.sort()

    assert ops ==
             ~w(abs chain divide minus minus_amount multiply_retain_scale negate new percentage_of plus plus_amount round_to_multiples_of times total)
  end

  test "every case matches Fineract's Money", %{cases: cases} do
    failures =
      cases
      |> Enum.chunk_every(1_000)
      |> Task.async_stream(fn chunk -> Enum.reject(chunk, &matches?/1) end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.flat_map(fn {:ok, bad} -> bad end)
      |> Enum.take(25)

    assert failures == [],
           "mismatches with Fineract (showing up to 25):\n" <>
             Enum.map_join(failures, "\n", &describe/1)
  end

  test "no case in the fixture is skipped by accident", %{cases: cases} do
    unsupported = Enum.reject(cases, &(&1["op"] in supported_ops()))
    assert unsupported == []
  end

  defp supported_ops,
    do:
      ~w(abs chain divide minus minus_amount multiply_retain_scale negate new percentage_of plus plus_amount round_to_multiples_of times total)

  defp matches?(case_) do
    expected = case_["result"]

    case run(case_) do
      {:ok, text} -> expected == text
      {:error, :arithmetic} -> expected == %{"error" => "arithmetic"}
    end
  end

  defp describe(case_) do
    got =
      case run(case_) do
        {:ok, text} -> inspect(text)
        {:error, reason} -> "error #{reason}"
      end

    "  #{case_["op"]} #{inspect(case_["args"])} #{inspect(case_["currency"])} tenant=#{case_["tenant_mode"]} mc=#{case_["mc_mode"]}: " <>
      "Fineract #{inspect(case_["result"])}, ours #{got}"
  end

  defp run(case_) do
    %{"currency" => c, "tenant_mode" => tenant, "mc_mode" => mc_mode, "args" => args, "op" => op} =
      case_

    currency = Currency.new(c["code"], c["places"], in_multiples_of: c["multiples"])
    # `rounding` is the MathContext's mode; the tenant's mode drives the "multiples of" step.
    ctx = Context.new(Rounding.from_int(mc_mode), multiples_rounding: Rounding.from_int(tenant))
    money = fn amount -> ECBMoney.new(currency, amount, ctx) end

    {:ok, ECBMoney.to_string(apply_op(op, args, money, ctx))}
  rescue
    ArithmeticError -> {:error, :arithmetic}
  end

  defp apply_op("new", [a], money, _ctx), do: money.(a)
  defp apply_op("plus", [a, b], money, _ctx), do: ECBMoney.plus(money.(a), money.(b))
  defp apply_op("plus_amount", [a, b], money, _ctx), do: ECBMoney.plus(money.(a), b)
  defp apply_op("minus", [a, b], money, _ctx), do: ECBMoney.minus(money.(a), money.(b))
  defp apply_op("minus_amount", [a, b], money, _ctx), do: ECBMoney.minus(money.(a), b)
  defp apply_op("times", [a, f], money, _ctx), do: ECBMoney.times(money.(a), f)
  defp apply_op("divide", [a, d], money, ctx), do: ECBMoney.divide(money.(a), d, ctx)

  defp apply_op("percentage_of", [a, p], money, ctx),
    do: ECBMoney.percentage_of(money.(a), p, ctx)

  defp apply_op("multiply_retain_scale", [a, f], money, ctx),
    do: ECBMoney.multiply_retain_scale(money.(a), f, ctx)

  defp apply_op("round_to_multiples_of", [a, m], money, ctx),
    do: ECBMoney.round_to_multiples_of(money.(a), String.to_integer(m), ctx)

  defp apply_op("negate", [a], money, _ctx), do: ECBMoney.negate(money.(a))
  defp apply_op("abs", [a], money, _ctx), do: ECBMoney.abs(money.(a))

  defp apply_op("total", [a, b, c], money, _ctx),
    do: ECBMoney.total([money.(a), money.(b), money.(c)])

  defp apply_op("chain", [a, b, f, d], money, ctx) do
    money.(a) |> ECBMoney.plus(money.(b)) |> ECBMoney.times(f) |> ECBMoney.divide(d, ctx)
  end
end
