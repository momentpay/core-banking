defmodule ECBOrg.Codes do
  @moduledoc """
  Code lists (`m_code`) and their values (`m_code_value`), read side. A code is a named list (client
  types, closure reasons, ...) whose values fill drop-downs. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "Every code, in the order of its name (byte order, as Fineract's database sorts it)."
  @spec list() :: [map]
  def list do
    base()
    |> order_by([c], asc: fragment("? COLLATE \"C\"", c.code_name))
    |> TenantRepo.all()
  end

  @doc "One code by id, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([c], c.id == ^id) |> TenantRepo.one() do
      nil -> {:error, id_not_found(id)}
      code -> {:ok, code}
    end
  end

  @doc "One code by name, or `{:error, ResourceNotFound}`."
  @spec get_by_name(String.t()) :: {:ok, map} | {:error, Exception.t()}
  def get_by_name(name) do
    case base() |> where([c], c.code_name == ^name) |> TenantRepo.one() do
      nil -> {:error, name_not_found(name)}
      code -> {:ok, code}
    end
  end

  @doc "Like `get/1` but raises the error. `shown` is how the id appears in the message."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, code} -> code
      {:error, _} -> raise name_not_found(Integer.to_string(id))
    end
  end

  @doc "Like `get/1` but raises the error, for work on the values of a code that must exist."
  @spec fetch_for_value!(integer) :: map
  def fetch_for_value!(id) do
    case get(id) do
      {:ok, code} -> code
      {:error, error} -> raise error
    end
  end

  @doc "The values of a code, by position then id; empty for a code that does not exist."
  @spec values(integer, keyword) :: [map]
  def values(code_id, opts \\ []) do
    order = if opts[:by_id], do: [asc: :id], else: [asc: :order_position, asc: :id]

    from(v in "m_code_value",
      where: v.code_id == ^code_id,
      select: %{
        id: v.id,
        name: v.code_value,
        description: v.code_description,
        position: v.order_position,
        active: v.is_active,
        mandatory: v.is_mandatory
      }
    )
    |> order_by(^order)
    |> TenantRepo.all()
  end

  @doc "One code value by id, or `{:error, ResourceNotFound}`."
  @spec get_value(integer) :: {:ok, map} | {:error, Exception.t()}
  def get_value(id) do
    from(v in "m_code_value",
      where: v.id == ^id,
      select: %{
        id: v.id,
        code_id: v.code_id,
        name: v.code_value,
        description: v.code_description,
        position: v.order_position,
        active: v.is_active,
        mandatory: v.is_mandatory
      }
    )
    |> TenantRepo.one()
    |> case do
      nil -> {:error, value_not_found(id)}
      value -> {:ok, value}
    end
  end

  @doc "Like `get_value/1` but raises the error."
  @spec fetch_value!(integer) :: map
  def fetch_value!(id) do
    case get_value(id) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  defp base,
    do:
      from(c in "m_code",
        select: %{id: c.id, name: c.code_name, system_defined: c.is_system_defined}
      )

  @doc false
  def id_not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.code.identifier.not.found",
        "Code with identifier `#{id}` does not exist",
        [id]
      )

  @doc false
  def name_not_found(name),
    do:
      ResourceNotFound.new(
        "error.msg.code.not.found",
        "Code with name `#{name}` does not exist",
        [name]
      )

  @doc false
  def value_not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.codevalue.id.invalid",
        "Code value with identifier #{id} does not exist",
        [id]
      )
end
