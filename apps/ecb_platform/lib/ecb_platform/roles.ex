defmodule ECBPlatform.Roles do
  @moduledoc "Roles (`m_role`), read side: the list and one role."
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "All roles, by id."
  @spec list() :: [map]
  def list, do: TenantRepo.all(base() |> order_by([r], r.id))

  @doc "One role, or `{:error, ResourceNotFound}`."
  @spec get(integer | String.t()) :: {:ok, map} | {:error, Exception.t()}
  def get(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> get(id)
      _ -> {:error, not_found(raw)}
    end
  end

  def get(id) when is_integer(id) do
    case TenantRepo.one(base() |> where([r], r.id == ^id)) do
      nil ->
        {:error, not_found(id)}

      role ->
        {:ok, role}
    end
  end

  defp not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.role.id.invalid",
        "Role with identifier #{id} does not exist",
        [id]
      )

  defp base do
    from r in "m_role",
      select: %{id: r.id, name: r.name, description: r.description, disabled: r.is_disabled}
  end
end
