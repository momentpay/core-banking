defmodule ECBPlatform.Permissions.Write do
  @moduledoc """
  Choosing which permissions are under maker-checker (`m_permission.can_maker_checker`).

  Only permissions that make sense to approve can be switched: not the `*_CHECKER` permissions, not the
  `READ_` ones and not the `special` group. Asking for any other reports it as unknown, as Fineract does.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{InvalidJson, ResourceNotFound}
  alias ECBPlatform.{Params, TenantRepo}

  @doc """
  Sets the maker-checker flag of each permission in `{"permissions": {"CODE": true}}`.
  """
  @spec update!(Params.t()) :: Result.t()
  def update!(%Params{} = params) do
    params = Params.check_supported!(params, ["permissions"])

    wanted =
      case Params.value(params, "permissions") do
        %{} = map -> map
        _ -> raise InvalidJson, detail: nil
      end

    changed =
      Enum.flat_map(wanted, fn {code, flag} ->
        permission = permission!(code)
        selected? = flag == true

        if selected? == permission.can_maker_checker,
          do: [],
          else: [{code, selected?, permission.id}]
      end)

    for {_code, selected?, id} <- changed do
      TenantRepo.update_all(from(p in "m_permission", where: p.id == ^id),
        set: [can_maker_checker: selected?]
      )
    end

    shown = for {code, selected?, _id} <- changed, into: %{}, do: {code, selected?}
    Result.new(changes: if(shown == %{}, do: %{}, else: %{"permissions" => shown}))
  end

  defp permission!(code) do
    row =
      TenantRepo.one(
        from p in "m_permission",
          where: p.code == ^code,
          select: %{id: p.id, grouping: p.grouping, can_maker_checker: p.can_maker_checker}
      )

    if row && not String.ends_with?(code, "_CHECKER") && not String.starts_with?(code, "READ_") &&
         String.downcase(row.grouping) != "special" do
      row
    else
      raise ResourceNotFound,
        code: "error.msg.permission.code.invalid",
        message: "Permission with Code #{code} does not exist",
        args: [code]
    end
  end
end
