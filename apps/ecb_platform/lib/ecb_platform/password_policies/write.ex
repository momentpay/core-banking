defmodule ECBPlatform.PasswordPolicies.Write do
  @moduledoc """
  Choosing which password validation policy is active (`m_password_validation_policy`): exactly one is.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @doc "Makes the policy named by `validationPolicyId` the active one."
  @spec update!(Params.t()) :: Result.t()
  def update!(%Params{} = params) do
    params = Params.check_supported!(params, ["validationPolicyId"])
    id = Params.long(params, "validationPolicyId")

    Validation.new("passwordpreferences")
    |> Validation.param("validationPolicyId", id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    policy =
      TenantRepo.one(
        from p in "m_password_validation_policy",
          where: p.id == ^id,
          select: %{id: p.id, active: p.active}
      ) ||
        raise ResourceNotFound,
          code: "error.msg.password.validation.policy.id.invalid",
          message: "Password Validation Policy with identifier #{id} does not exist",
          args: [id]

    if policy.active do
      Result.new(changes: %{})
    else
      TenantRepo.update_all("m_password_validation_policy", set: [active: false])

      TenantRepo.update_all(from(p in "m_password_validation_policy", where: p.id == ^id),
        set: [active: true]
      )

      Result.new(changes: %{"active" => true})
    end
  end
end
