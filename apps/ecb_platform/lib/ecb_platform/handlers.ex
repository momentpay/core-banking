defmodule ECBPlatform.Handlers do
  @moduledoc """
  The command handlers of the platform itself (roles, users, configuration, ...), one module per
  command. Each reads the request body from the command and calls the module that does the work.
  """

  defmodule CreateRole do
    @moduledoc "`CREATE` on `ROLE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBPlatform.Roles.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateRole do
    @moduledoc "`UPDATE` on `ROLE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBPlatform.Roles.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule DeleteRole do
    @moduledoc "`DELETE` on `ROLE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBPlatform.Roles.Write.delete!(command.entity_id)}
  end

  defmodule EnableRole do
    @moduledoc "`ENABLE` on `ROLE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBPlatform.Roles.Write.enable!(command.entity_id)}
  end

  defmodule DisableRole do
    @moduledoc "`DISABLE` on `ROLE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBPlatform.Roles.Write.disable!(command.entity_id)}
  end

  defmodule UpdateRolePermissions do
    @moduledoc "`PERMISSIONS` on `ROLE`: grant and withdraw the permissions a role holds."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBPlatform.Roles.Write.update_permissions!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule CreateUser do
    @moduledoc "`CREATE` on `USER`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBPlatform.Users.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateUser do
    @moduledoc "`UPDATE` on `USER`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBPlatform.Users.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule DeleteUser do
    @moduledoc "`DELETE` on `USER`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user), do: {:ok, ECBPlatform.Users.Write.delete!(command.entity_id)}
  end

  defmodule ChangeUserPassword do
    @moduledoc "`CHANGEPWD` on `USER`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBPlatform.Users.Write.change_password!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule UpdateConfiguration do
    @moduledoc "`UPDATE` on `CONFIGURATION`: a global configuration property."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBPlatform.Configuration.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule UpdatePasswordPreferences do
    @moduledoc "`UPDATE` on `PASSWORD_PREFERENCES`: the active password policy."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok, ECBPlatform.PasswordPolicies.Write.update!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateMakerCheckerPermissions do
    @moduledoc "`UPDATE` on `PERMISSION`: which permissions are under maker-checker."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBPlatform.Permissions.Write.update!(ECBPlatform.Params.parse!(command.json))}
  end
end
