defmodule ECBLedger.Errors do
  @moduledoc "Errors of the ledger that need a shape of their own."

  defmodule InvalidOrderBy do
    @moduledoc """
    An `orderBy` or `sortOrder` that is not a column of the query. Fineract puts the text into its SQL and the
    database refuses it, which is a plain server error; the API answers the same.
    """
    defexception [:value]

    @impl true
    def message(%{value: value}), do: "cannot order by #{inspect(value)}"
  end
end
