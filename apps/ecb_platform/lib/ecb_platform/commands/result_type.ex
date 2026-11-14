defmodule ECBPlatform.Commands.ResultType do
  @moduledoc """
  The status of a stored command, with the integers Fineract keeps in
  `m_portfolio_command_source.status`.

  | Code | Name                 | Meaning                                                          |
  |-----:|----------------------|------------------------------------------------------------------|
  | 0    | `:invalid`           | unknown                                                          |
  | 1    | `:processed`         | executed (and, under maker-checker, approved)                    |
  | 2    | `:awaiting_approval` | validated but rolled back, waiting for a checker                 |
  | 3    | `:rejected`          | a checker rejected it                                            |
  | 4    | `:under_processing`  | being executed now (also what a crashed request leaves behind)   |
  | 5    | `:error`             | failed; the error is stored in the result columns                |

  Mirrors `org.apache.fineract.commands.domain.CommandProcessingResultType`.
  """

  @codes %{
    invalid: 0,
    processed: 1,
    awaiting_approval: 2,
    rejected: 3,
    under_processing: 4,
    error: 5
  }
  @names Map.new(@codes, fn {name, code} -> {code, name} end)

  @type t :: :invalid | :processed | :awaiting_approval | :rejected | :under_processing | :error

  @spec to_int(t()) :: 0..5
  def to_int(type), do: Map.fetch!(@codes, type)

  @doc "Unknown codes (and `nil`) give `:invalid`, as in Fineract."
  @spec from_int(integer | nil) :: t()
  def from_int(code), do: Map.get(@names, code, :invalid)
end
