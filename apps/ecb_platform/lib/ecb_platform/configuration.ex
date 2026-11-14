defmodule ECBPlatform.Configuration do
  @moduledoc """
  Global configuration (`c_configuration`) and the per-permission maker-checker flag
  (`m_permission.can_maker_checker`).

  Reads go to the tenant database each time for now; a cache comes with the configuration API. Must
  run inside `ECBPlatform.Tenancy.with_tenant/2`.

  Maker-checker is on for a task only when **both** are true: the global `maker-checker` setting is
  enabled, and the task's permission row has `can_maker_checker` set. This is Fineract's rule
  (`ConfigurationDomainServiceJpa.isMakerCheckerEnabledForTask`).
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Errors.PermissionNotFound
  alias ECBPlatform.TenantRepo

  @maker_checker "maker-checker"
  @same_maker_checker "enable-same-maker-checker"

  @doc "One configuration row as a map, or `nil` when there is none."
  @spec get(String.t()) :: map | nil
  def get(name) do
    TenantRepo.one(
      from c in "c_configuration",
        where: c.name == ^name,
        select: %{
          name: c.name,
          enabled: c.enabled,
          value: c.value,
          string_value: c.string_value,
          date_value: c.date_value
        }
    )
  end

  @doc "True when the configuration exists and is enabled. A missing row is treated as disabled."
  @spec enabled?(String.t()) :: boolean
  def enabled?(name), do: match?(%{enabled: true}, get(name))

  @doc """
  Whether a command's permission code is under maker-checker. Raises `PermissionNotFound` for a blank
  or unknown code, as Fineract does.
  """
  @spec maker_checker_enabled_for_task?(String.t()) :: boolean
  def maker_checker_enabled_for_task?(task) when task in [nil, ""],
    do: raise(PermissionNotFound, code: task)

  def maker_checker_enabled_for_task?(task) do
    if enabled?(@maker_checker) do
      case TenantRepo.one(
             from p in "m_permission", where: p.code == ^task, select: p.can_maker_checker
           ) do
        nil -> raise PermissionNotFound, code: task
        flag -> flag
      end
    else
      false
    end
  end

  @doc "Whether the maker may also be the checker (`enable-same-maker-checker`)."
  @spec same_maker_checker_enabled?() :: boolean
  def same_maker_checker_enabled?, do: enabled?(@same_maker_checker)
end
