defmodule ECBApiFineract do
  @moduledoc """
  The Fineract-compatible REST API: the paths, JSON shapes, status codes and headers that existing
  Fineract clients (and the Mifos apps) expect, over E-CoreBank's own domain modules.

  It owns no business rules. A request is resolved to a tenant, authenticated with HTTP basic
  authentication, and handed to a domain module; this layer only translates.

  Mounted by the web endpoint at `/fineract-provider`:

    * `GET /fineract-provider/actuator/health`
    * `/fineract-provider/api/v1/...` (needs the `Fineract-Platform-TenantId` header and credentials)

  Every response is checked against the real Fineract by `parity/tools/contract_probe.py`.
  """
end
