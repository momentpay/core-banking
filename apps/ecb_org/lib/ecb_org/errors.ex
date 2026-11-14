defmodule ECBOrg.Errors do
  @moduledoc "Errors returned by the organisation contexts. The API layer turns them into Fineract's responses."

  defmodule OfficeNotFound do
    @moduledoc "No office with that id. HTTP 404, code `error.msg.office.id.invalid`."
    defexception [:office_id]

    @impl true
    def message(%{office_id: id}), do: "Office with identifier #{id} does not exist"
  end

  defmodule InvalidOrdering do
    @moduledoc "An `orderBy` or `sortOrder` value that is not allowed. HTTP 403, as Fineract answers."
    defexception [:detail]

    @impl true
    def message(%{detail: detail}), do: detail
  end
end
