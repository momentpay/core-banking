defmodule ECBApiFineract.FixturesTest do
  @moduledoc """
  For every request in the fixtures manifest that is not pending, E-CoreBank must answer exactly what
  Apache Fineract answered on the same seeded data: the same status and the same JSON.

  The fixtures are recorded with `python parity/tools/capture_fixtures.py capture` (needs the running
  oracle). Set `"pending": true` in the manifest for an endpoint that is not built yet, and remove it
  when it is: that is the to-do list for the compatible API, and this test is its definition of done.

  Object key order is not compared (it carries no meaning in JSON); list order is.
  """
  use ECBApiFineract.ApiCase

  @fixtures Path.expand("../fixtures/fineract", __DIR__)
  @manifest_path Path.join(@fixtures, "manifest.json")
  @external_resource @manifest_path
  @entries @manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("entries")

  for entry <- @entries, not Map.get(entry, "pending", false) do
    @entry entry
    test "#{entry["path"]} answers what Fineract answers" do
      entry = @entry
      fixture = Path.join(@fixtures, entry["name"] <> ".json") |> File.read!() |> Jason.decode!()

      conn = call(:get, "/api" <> entry["path"], auth: admin())
      actual = normalize(body(conn), Map.get(entry, "today_keys", []))
      expected = fixture["body"]

      assert conn.status == fixture["status"],
             "#{entry["path"]}: HTTP #{conn.status}, Fineract answered #{fixture["status"]}"

      case first_difference(expected, actual, "$") do
        nil ->
          :ok

        {path, want, got} ->
          flunk(
            "#{entry["path"]} differs from Fineract at #{path}\n  Fineract: #{inspect(want, limit: 8, printable_limit: 120)}\n  ours:     #{inspect(got, limit: 8, printable_limit: 120)}"
          )
      end
    end
  end

  test "the manifest has at least one built entry per fixture file, and no stray fixture files" do
    names = MapSet.new(@entries, & &1["name"])

    files =
      Path.wildcard(Path.join(@fixtures, "*.json"))
      |> Enum.map(&Path.basename(&1, ".json"))
      |> MapSet.new()
      |> MapSet.delete("manifest")
      |> MapSet.delete("scenarios")

    assert MapSet.difference(files, names) == MapSet.new(), "fixture files not in the manifest"

    assert MapSet.difference(names, files) == MapSet.new(),
           "manifest entries without a fixture file: run capture_fixtures.py capture"
  end

  # Today's date is stored as a marker so the fixture does not go stale: anything that looks like a date
  # array under one of the listed keys becomes the same marker.
  defp normalize(value, []), do: value

  defp normalize(%{} = map, keys) do
    Map.new(map, fn
      {k, [y, m, d]} when is_integer(y) and is_integer(m) and is_integer(d) ->
        if k in keys, do: {k, "__TODAY__"}, else: {k, [y, m, d]}

      {k, v} ->
        {k, normalize(v, keys)}
    end)
  end

  defp normalize(list, keys) when is_list(list), do: Enum.map(list, &normalize(&1, keys))
  defp normalize(other, _keys), do: other
end
