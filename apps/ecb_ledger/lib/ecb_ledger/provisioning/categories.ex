defmodule ECBLedger.Provisioning.Categories do
  @moduledoc """
  The categories loan provisioning sorts loans into (`m_provision_category`: standard, sub-standard,
  doubtful, loss, and any the bank adds), following Fineract's `ProvisioningCategory*` services. A category
  that a provisioning criteria uses cannot be deleted. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Integrity, Params, TenantRepo, Validation}

  @supported ~w(categoryname categorydescription)

  @doc "Every category, by id."
  @spec list() :: [map]
  def list,
    do:
      from(c in "m_provision_category",
        order_by: c.id,
        select: %{id: c.id, name: c.category_name, description: c.description}
      )
      |> TenantRepo.all()

  @doc "One category, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case Enum.find(list(), &(&1.id == id)) do
      nil -> {:error, not_found(id)}
      category -> {:ok, category}
    end
  end

  @doc "Like `get/1` but raises the error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, category} -> category
      {:error, error} -> raise error
    end
  end

  # --- write ----------------------------------------------------------------------------------

  @doc "Adds the category in `params`. Only its name can be given here, as in Fineract."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    Params.check_supported!(params, @supported)
    name = Params.string(params, "categoryname")

    Validation.new("provisioningcategories")
    |> Validation.param("categoryname", name)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    {1, [%{id: id}]} =
      guard(fn ->
        TenantRepo.insert_all(
          "m_provision_category",
          [%{category_name: name, description: Params.command_string(params, "description")}],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id)
  end

  @doc "Changes a category's name or description."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    Params.check_supported!(params, @supported)

    if Params.exists?(params, "categoryname") do
      Validation.new("provisioningcategories")
      |> Validation.param("categoryname", Params.string(params, "categoryname"))
      |> Validation.not_blank()
      |> Validation.max_length(100)
      |> Validation.raise_if_errors!()
    end

    category = fetch!(id)

    {changes, set} =
      {%{}, []}
      |> change(params, "categoryname", category.name, :category_name)
      |> change(params, "categorydescription", category.description, :description)

    unless set == [] do
      guard(fn ->
        TenantRepo.update_all(from(c in "m_provision_category", where: c.id == ^id), set: set)
      end)
    end

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  @doc "Deletes a category no criteria uses."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    fetch!(id)

    if TenantRepo.exists?(
         from(d in "m_provisioning_criteria_definition", where: d.category_id == ^id)
       ),
       do:
         raise(DomainRuleViolation,
           code:
             "error.msg.provisioningcategory.cannot.be.deleted.it.is.already.used.in.loanproduct",
           message:
             "This provisioning category cannot be deleted, it is already used in loan product",
           args: []
         )

    TenantRepo.delete_all(from(c in "m_provision_category", where: c.id == ^id))
    Result.new(resource_id: id)
  end

  # --- internals ------------------------------------------------------------------------------

  defp change({changes, set}, params, key, existing, column) do
    if Params.changed_string?(params, key, existing) do
      value = Params.command_string(params, key)
      {Map.put(changes, key, value), [{column, value} | set]}
    else
      {changes, set}
    end
  end

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.provisioning.id.invalid",
        "Provisioning Category with identifier #{id} does not exist",
        [id]
      )

  # Fineract looks for the new name under a key it never wrote, so its message names an empty one (and
  # misspells "Category"); both are kept.
  defp guard(fun) do
    Integrity.translate(
      fun,
      %{
        "m_provision_category_category_name_key" =>
          {"error.msg.provisioning.duplicate.categoryname",
           "Provisioning Cateory with name `` already exists", "category name", [""]}
      },
      {"error.msg.charge.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end
end
