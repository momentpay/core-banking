defmodule ECBLedger.AccountingRules.JavaOrder do
  @moduledoc """
  The order in which Java's `HashSet<String>` hands its elements back.

  Fineract keeps the tags of a rule in `HashSet`s, so the order in which a rule's tags are written and
  reported (`"changes": {"debitTags": ["23", "24"]}`) is the set's, not the request's. A client compares
  those answers, so the same order is reproduced: elements go into a table of 16 buckets (more as the set
  grows, and fewer than 13 tags never do), by their Java string hash with the high bits folded in, and come
  out bucket by bucket; two elements in one bucket keep the order they went in.
  """
  import Bitwise

  @doc """
  `strings` without repeats, in the order a `HashSet` built by adding them one after another iterates.
  """
  @spec order([String.t()]) :: [String.t()]
  def order(strings) do
    unique = Enum.uniq(strings)
    size = table_size(length(unique))

    unique
    |> Enum.with_index()
    |> Enum.sort_by(fn {string, index} -> {bucket(string, size), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  # the table doubles whenever more than three quarters of it is used
  defp table_size(count), do: grow(16, count)
  defp grow(size, count) when count > size * 3 / 4, do: grow(size * 2, count)
  defp grow(size, _count), do: size

  defp bucket(string, size) do
    hash = java_hash(string)
    bxor(hash, hash >>> 16) &&& size - 1
  end

  # `String.hashCode()`: s[0]*31^(n-1) + ... + s[n-1], as a 32-bit number (taken as unsigned here, which
  # leaves the bits the bucket uses the same)
  defp java_hash(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, hash -> hash * 31 + char &&& 0xFFFFFFFF end)
  end
end
