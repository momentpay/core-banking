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
  alias ECBPlatform.Errors.ResourceNotFound
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

  @options_file Path.expand("../../priv/configuration_options.json", __DIR__)
  @external_resource @options_file
  @options @options_file |> File.read!() |> Jason.decode!()

  @doc """
  Every global configuration property as the configuration API lists it: the row plus, for the few
  string-valued properties, the values they may take.
  """
  @spec list() :: [map]
  def list do
    from(c in "c_configuration", order_by: c.id, select: ^fields())
    |> TenantRepo.all()
    |> Enum.map(&with_options/1)
  end

  @doc "One property by name, or `{:error, ResourceNotFound}`."
  @spec get_by_name(String.t()) :: {:ok, map} | {:error, Exception.t()}
  def get_by_name(name) when is_binary(name) do
    case TenantRepo.one(from(c in "c_configuration", where: c.name == ^name, select: ^fields())) do
      nil ->
        {:error,
         ResourceNotFound.new(
           "error.msg.configuration.property.invalid",
           "Configuration property `#{name}` does not exist",
           [name]
         )}

      row ->
        {:ok, with_options(row)}
    end
  end

  defp fields do
    dynamic(
      [c],
      %{
        id: c.id,
        name: c.name,
        enabled: c.enabled,
        value: c.value,
        string_value: c.string_value,
        date_value: c.date_value,
        trap_door: c.is_trap_door,
        description: c.description
      }
    )
  end

  defp with_options(row) do
    case Map.get(@options, row.name) do
      nil ->
        row

      %{"allowedValues" => allowed, "multipleValuesAllowed" => multiple} ->
        Map.merge(row, %{allowed_values: allowed, multiple_values_allowed: multiple})
    end
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
