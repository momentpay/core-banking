defmodule ECBOrg.Offices.CreateHandler do
  @moduledoc "The command `CREATE` on `OFFICE`."
  @behaviour ECBPlatform.Commands.Handler

  alias ECBOrg.Offices.Write
  alias ECBPlatform.Params

  @impl true
  def process(command, user), do: {:ok, Write.create!(user, Params.parse!(command.json))}
end

defmodule ECBOrg.Offices.UpdateHandler do
  @moduledoc "The command `UPDATE` on `OFFICE`."
  @behaviour ECBPlatform.Commands.Handler

  alias ECBOrg.Offices.Write
  alias ECBPlatform.Params

  @impl true
  def process(command, user),
    do: {:ok, Write.update!(user, command.entity_id, Params.parse!(command.json))}
end
