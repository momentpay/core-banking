defmodule ECBPlatform do
  @moduledoc """
  The E-CoreBank platform layer: tenant registry and tenant scoping, and (as they are
  built) authentication, maker-checker, the command bus, audit, idempotency, the outbox
  and the business-date clock.

  Domain apps (`ecb_ledger`, `ecb_loans`, ...) depend on this app. This app depends on none
  of them.
  """
end
