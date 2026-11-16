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

    @tag scenario: @scenario["name"]
    test "scenario #{@scenario["name"]} answers what Fineract answers" do
      scenario = @scenario

      scenario["steps"]
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {step, number}, vars ->
        run_step(scenario["name"], step, number, vars)
      end)
    end
  end

  defp run_step(name, step, number, vars) do
    step = substitute(step, vars)
    method = step |> Map.get("method", "GET") |> String.downcase() |> String.to_atom()
    label = "#{name} step #{number}: #{String.upcase(to_string(method))} #{step["path"]}"

    auth =
      case step["auth"] do
        [user, password] -> {user, password}
        nil -> admin()
      end

    conn =
      case {step["raw"], step["body"]} do
        {raw, _} when is_binary(raw) ->
          call_raw(method, "/api" <> step["path"], raw)

        {_, body} when is_map(body) ->
          call(method, "/api" <> step["path"], auth: auth, body: body)

        _ ->
          call(method, "/api" <> step["path"], auth: auth)
      end

    ignored = step["ignore"] || []

    assert conn.status == step["status"],
           "#{label}: HTTP #{conn.status}, Fineract answered #{step["status"]}\n  ours: #{conn.resp_body}"

    sortby = step["sortby"]

    case first_difference(
           in_order(mask(step["response"], ignored), sortby),
           in_order(mask(body(conn), ignored), sortby),
           "$"
         ) do
      nil ->
        :ok

      {path, want, got} ->
        flunk(
          "#{label} differs from Fineract at #{path}\n  Fineract: #{inspect(want, limit: 8, printable_limit: 200)}\n  ours:     #{inspect(got, limit: 8, printable_limit: 200)}"
        )
    end

    save(step["save"], body(conn), vars)
  end

  # Values a step keeps from its answer for later steps (`"save": {"tx": "transactionId"}`), such as the
  # generated transaction id of a journal entry, which a reversal then names in its path as `{tx}`.
  defp save(nil, _answer, vars), do: vars

  defp save(wanted, answer, vars),
    do: Enum.reduce(wanted, vars, fn {name, key}, acc -> Map.put(acc, name, answer[key]) end)

  defp substitute(step, vars) when vars == %{}, do: step

  defp substitute(step, vars) do
    step
    |> Map.update!("path", &replace_vars(&1, vars))
    |> Map.update!("response", &replace_vars(&1, vars))
    |> then(fn s ->
      if is_map(s["body"]), do: Map.update!(s, "body", &replace_vars(&1, vars)), else: s
    end)
  end

  defp replace_vars(%{} = map, vars),
    do: Map.new(map, fn {k, v} -> {k, replace_vars(v, vars)} end)

  defp replace_vars(list, vars) when is_list(list), do: Enum.map(list, &replace_vars(&1, vars))

  defp replace_vars(text, vars) when is_binary(text) do
    Enum.reduce(vars, text, fn {name, value}, acc ->
      String.replace(acc, "{" <> name <> "}", to_string(value))
    end)
  end

  defp replace_vars(other, _vars), do: other

  # A list Fineract answers in the order its database happens to hold the rows (`"sortby": "id"` in the
  # step) is compared in the order of that key, on both sides; a page's items count as the list.
  defp in_order(value, nil), do: value

  defp in_order(list, key) when is_list(list),
    do: Enum.sort_by(list, fn item -> if is_map(item), do: item[key] end)

  defp in_order(%{"pageItems" => items} = page, key),
    do: %{page | "pageItems" => in_order(items, key)}

  defp in_order(other, _key), do: other

  # Values that cannot repeat from run to run (times, the caller's address) are left out on both sides.
  defp mask(value, []), do: value

  # A key written `parent.child` is blanked only inside `parent` (`debitTags.id` blanks the ids of the
  # tag rows and not the rule's own id).
  # An ignored key is dropped from both sides, so it need not be present in both.
  defp mask(%{} = map, keys) do
    map
    |> Map.reject(fn {k, _v} -> k in keys end)
    |> Map.new(fn {k, v} -> {k, mask(v, keys ++ inside(keys, k))} end)
  end

  defp mask(list, keys) when is_list(list), do: Enum.map(list, &mask(&1, keys))
  defp mask(other, _keys), do: other

  defp inside(keys, parent) do
    prefix = parent <> "."
    for key <- keys, String.starts_with?(key, prefix), do: String.replace_prefix(key, prefix, "")
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
