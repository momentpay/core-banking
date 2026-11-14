defmodule ECBOrg.Codes.Write do
  @moduledoc """
  Creating, changing and deleting codes and their values, following Fineract's code services.

  A system-defined code (one the platform ships) cannot be renamed or deleted, but values can be added
  to it. Deleting a value that belongs to another code does nothing and answers as if it worked, as
  Fineract does.
  """
  import Ecto.Query

  alias ECBOrg.Codes
  alias ECBPlatform.Changes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.{Integrity, Params, TenantRepo, Validation}

  @value_params ~w(name description position isActive isMandatory)

  # --- codes ----------------------------------------------------------------------------------

  @doc "Creates the code `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    params = Params.check_supported!(params, ["name"])
    name = Params.string(params, "name")

    Validation.new("code")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    {1, [%{id: id}]} =
      guard_code(name, fn ->
        TenantRepo.insert_all(
          "m_code",
          [%{code_name: String.trim(name), is_system_defined: false}],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id)
  end

  @doc "Renames code `id`."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    params = Params.check_supported!(params, ["name"])

    if Params.exists?(params, "name") do
      Validation.new("code")
      |> Validation.param("name", Params.string(params, "name"))
      |> Validation.not_blank()
      |> Validation.max_length(100)
      |> Validation.raise_if_errors!()
    end

    code = Codes.fetch!(id)
    if code.system_defined, do: raise(system_defined())

    changes = Changes.text(Changes.new(), params, "name", :code_name, code.name)

    unless Changes.empty?(changes) do
      guard_code(Params.string(params, "name"), fn ->
        TenantRepo.update_all(from(c in "m_code", where: c.id == ^id), set: Changes.set(changes))
      end)
    end

    Result.new(resource_id: id, changes: Changes.public(changes))
  end

  @doc "Deletes code `id` and its values; refused for a system-defined code."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    code = Codes.fetch!(id)
    if code.system_defined, do: raise(system_defined())

    Integrity.translate(
      fn ->
        TenantRepo.delete_all(from(v in "m_code_value", where: v.code_id == ^id))
        TenantRepo.delete_all(from(c in "m_code", where: c.id == ^id))
      end,
      %{},
      {"error.msg.cund.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )

    Result.new(resource_id: id)
  end

  # --- code values ----------------------------------------------------------------------------

  @doc "Adds a value to code `code_id`."
  @spec create_value!(integer, Params.t()) :: Result.t()
  def create_value!(code_id, %Params{} = params) do
    params = Params.check_supported!(params, @value_params)
    name = Params.string(params, "name")

    Validation.new("code.value")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> optional(params, "description", &Validation.max_length(&1, 500))
    |> Validation.raise_if_errors!()

    position = Params.integer(params, "position") || 0
    _code = Codes.fetch_for_value!(code_id)

    {1, [%{id: id}]} =
      guard_value(name, fn ->
        TenantRepo.insert_all(
          "m_code_value",
          [
            %{
              code_id: code_id,
              code_value: name && String.trim(name),
              code_description: Params.command_string(params, "description"),
              order_position: position,
              is_active: Params.boolean(params, "isActive") != false,
              is_mandatory: Params.boolean(params, "isMandatory") || false
            }
          ],
          returning: [:id]
        )
      end)

    Result.new(resource_id: code_id, subresource_id: id)
  end

  @doc "Changes code value `id`."
  @spec update_value!(integer, Params.t()) :: Result.t()
  def update_value!(id, %Params{} = params) do
    params = Params.check_supported!(params, @value_params)

    validation = Validation.new("code.value")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank()
          |> Validation.max_length(100),
        else: validation

    validation
    |> optional(params, "description", &Validation.max_length(&1, 500))
    |> Validation.raise_if_errors!()

    # reading the position refuses a value that is not a whole number
    _ = Params.integer(params, "position")
    value = Codes.fetch_value!(id)

    changes =
      Changes.new()
      |> Changes.text(params, "name", :code_value, value.name)
      |> Changes.text(params, "description", :code_description, value.description)
      |> Changes.integer(params, "position", :order_position, value.position)
      |> Changes.boolean(params, "isActive", :is_active, value.active)

    unless Changes.empty?(changes) do
      guard_value(Params.string(params, "name"), fn ->
        TenantRepo.update_all(from(v in "m_code_value", where: v.id == ^id),
          set: Changes.set(changes)
        )
      end)
    end

    Result.new(resource_id: id, changes: Changes.public(changes))
  end

  @doc "Deletes code value `value_id` of code `code_id`; a value of another code is left alone."
  @spec delete_value!(integer, integer) :: Result.t()
  def delete_value!(code_id, value_id) do
    _code = Codes.fetch_for_value!(code_id)
    value = Codes.fetch_value!(value_id)

    if value.code_id == code_id do
      Integrity.translate(
        fn -> TenantRepo.delete_all(from(v in "m_code_value", where: v.id == ^value_id)) end,
        %{},
        {"error.msg.codeValue.in.use", "This code value is in use"}
      )
    end

    Result.new(resource_id: code_id, subresource_id: value_id)
  end

  # --- internals ------------------------------------------------------------------------------

  defp optional(validation, params, key, check) do
    if Params.exists?(params, key),
      do: validation |> Validation.param(key, Params.string(params, key)) |> check.(),
      else: validation
  end

  defp system_defined,
    do: %DomainRuleViolation{
      code: "error.msg.code.systemdefined",
      message: "This code is system defined and cannot be modified or deleted.",
      args: []
    }

  defp guard_code(name, fun) do
    Integrity.translate(
      fun,
      %{
        "m_code_code_name_key" =>
          {"error.msg.code.duplicate.name", "A code with name '#{name}' already exists", "name",
           [name]}
      },
      {"error.msg.cund.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end

  defp guard_value(name, fun) do
    Integrity.translate(
      fun,
      %{
        "code_value" =>
          {"error.msg.code.value.duplicate.label",
           "A code value with lable '#{name}' already exists", "name", [name]}
      },
      {"error.msg.code.value.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end
end
