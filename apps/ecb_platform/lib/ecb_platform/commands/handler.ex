defmodule ECBPlatform.Commands.Handler do
  @moduledoc """
  The behaviour a domain module implements to carry out one command: the equivalent of Fineract's
  `NewCommandSourceHandler`.

  A handler is plain business logic. It does not check permissions, maker-checker or idempotency, and
  it does not store the command: the pipeline does all of that around it. It runs inside a database
  transaction, so any write it makes is undone if it returns an error, raises, or if the command turns
  out to need a checker's approval.

  Return `{:ok, result}`, or `{:error, exception}` for a failure the caller should see (a validation
  error, for instance). To make a command that has to be approved report success only once approved,
  nothing special is needed: the pipeline rolls the handler's writes back and parks the command.

  Set `rollback_transaction: true` on the result to ask for a dry run: the work is validated and then
  rolled back unless a checker approves it (Fineract uses this for maker-checker on specific tasks).

  Register a handler with `ECBPlatform.Commands.Handlers.register/3`.
  """

  alias ECBPlatform.Commands.{Command, Result}
  alias ECBPlatform.Security.User

  @callback process(Command.t(), User.t()) :: {:ok, Result.t()} | {:error, Exception.t()}
end
