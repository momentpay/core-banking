defmodule ECBPlatform.Security.User do
  @moduledoc """
  The signed-in user as far as authorisation is concerned: who they are and which permission codes
  their roles grant.

  Permission rules follow Fineract's `AppUser`:

    * A user with `ALL_FUNCTIONS` can do anything.
    * Otherwise a user needs the specific code, for example `CREATE_CLIENT`.
    * A *checker* for a task has `<ACTION>_<ENTITY>_CHECKER`, or the global `CHECKER_SUPER_USER`.
  """

  @enforce_keys [:id, :username]
  defstruct [:id, :username, :office_id, permissions: MapSet.new()]

  @type t :: %__MODULE__{
          id: integer,
          username: String.t(),
          office_id: integer | nil,
          permissions: MapSet.t(String.t())
        }

  @all_functions "ALL_FUNCTIONS"
  @checker_super_user "CHECKER_SUPER_USER"

  @doc "Builds a user from a list or set of permission codes."
  @spec new(integer, String.t(), Enumerable.t(), keyword) :: t()
  def new(id, username, permissions, opts \\ []) do
    %__MODULE__{
      id: id,
      username: username,
      office_id: Keyword.get(opts, :office_id),
      permissions: MapSet.new(permissions)
    }
  end

  @doc "True when the user holds `ALL_FUNCTIONS`."
  @spec all_functions?(t()) :: boolean
  def all_functions?(%__MODULE__{permissions: permissions}),
    do: MapSet.member?(permissions, @all_functions)

  @doc "True when the user may do `code`: they hold it, or `ALL_FUNCTIONS`."
  @spec has_permission?(t(), String.t()) :: boolean
  def has_permission?(%__MODULE__{} = user, code),
    do: all_functions?(user) or MapSet.member?(user.permissions, code)

  @doc "True when the user holds none of the codes (and not `ALL_FUNCTIONS`)."
  @spec has_not_permission_for_any_of?(t(), [String.t()]) :: boolean
  def has_not_permission_for_any_of?(%__MODULE__{} = user, codes),
    do: not Enum.any?(codes, &has_permission?(user, &1))

  @doc "True for a user who can approve any maker-checker task."
  @spec checker_super_user?(t()) :: boolean
  def checker_super_user?(%__MODULE__{} = user), do: has_permission?(user, @checker_super_user)

  @doc "The permission code that makes a user a checker for `task`."
  @spec checker_permission(String.t()) :: String.t()
  def checker_permission(task), do: String.upcase(task) <> "_CHECKER"
end
