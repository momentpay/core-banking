defmodule ECBApiFineract.ScenariosTest do
  @moduledoc """
  Replays sequences of writes that were first run against Apache Fineract and requires every response,
  status and JSON, to be the same from E-CoreBank.

  A scenario (`test/fixtures/fineract/scenarios/<name>.json`) starts from the seeded data. Each step is
  a request and what Fineract answered; the steps run in order, so a later step sees the effect of the
  earlier ones. Record scenarios with `python parity/tools/capture_fixtures.py scenarios`; they are
  described in `scenarios.json`. Object key order is not compared.
  """
  use ECBApiFineract.ApiCase

  @fixtures Path.expand("../fixtures/fineract", __DIR__)
  @scenario_files Path.wildcard(Path.join([@fixtures, "scenarios", "*.json"]))

  for file <- @scenario_files do
    @external_resource file
    @scenario file |> File.read!() |> Jason.decode!()

    test "scenario #{@scenario["name"]} answers what Fineract answers" do
      scenario = @scenario

      scenario["steps"]
      |> Enum.with_index(1)
      |> Enum.each(fn {step, number} -> run_step(scenario["name"], step, number) end)
    end
  end

  defp run_step(name, step, number) do
    method = step |> Map.get("method", "GET") |> String.downcase() |> String.to_atom()
    label = "#{name} step #{number}: #{String.upcase(to_string(method))} #{step["path"]}"

    conn =
      case {step["raw"], step["body"]} do
        {raw, _} when is_binary(raw) ->
          call_raw(method, "/api" <> step["path"], raw)

        {_, body} when is_map(body) ->
          call(method, "/api" <> step["path"], auth: admin(), body: body)

        _ ->
          call(method, "/api" <> step["path"], auth: admin())
      end

    assert conn.status == step["status"],
           "#{label}: HTTP #{conn.status}, Fineract answered #{step["status"]}\n  ours: #{conn.resp_body}"

    case first_difference(step["response"], body(conn), "$") do
      nil ->
        :ok

      {path, want, got} ->
        flunk(
          "#{label} differs from Fineract at #{path}\n  Fineract: #{inspect(want, limit: 8, printable_limit: 200)}\n  ours:     #{inspect(got, limit: 8, printable_limit: 200)}"
        )
    end
  end

  # A request whose body is sent as given (for malformed JSON), signed in as the administrator.
  defp call_raw(method, path, raw) do
    {user, password} = admin()

    Plug.Test.conn(method, path, raw)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("fineract-platform-tenantid", "apitest")
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64(user <> ":" <> password)
    )
    |> then(&ECBApiFineract.Router.call(&1, ECBApiFineract.Router.init([])))
  end
end
