defmodule ECBLedger.Provisioning.Criteria do
  @moduledoc """
  Provisioning criteria (`m_provisioning_criteria` and its definitions), read side, following Fineract's
  `ProvisioningCriteriaReadPlatformServiceImpl`.

  A criteria says how much of a loan to set aside as it ages: per category, an age band in days and a
  percentage, with the liability and expense accounts the provision is posted to. It applies to a set of
  loan products. Loan products are built later, so no criteria lists any yet and creating, changing and
  deleting criteria wait for them. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.GLAccounts
  alias ECBLedger.Provisioning.Categories
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  @doc "Every criteria with the name of the user who made it."
  @spec list() :: [map]
  def list,
    do:
      from(c in "m_provisioning_criteria",
        left_join: u in "m_appuser",
        on: u.id == c.createdby_id,
        select: %{id: c.id, name: c.criteria_name, created_by: u.username}
      )
      |> TenantRepo.all()

  @doc "One criteria with its definitions, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case TenantRepo.one(
           from(c in "m_provisioning_criteria", where: c.id == ^id, select: c.criteria_name)
         ) do
      nil -> {:error, not_found(id)}
      name -> {:ok, %{id: id, name: name, loan_products: [], definitions: definitions(id)}}
    end
  end

  @doc """
  What a form needs to define a criteria: a definition slot for each category, the loan products to choose
  from (none yet) and the enabled detail accounts.
  """
  @spec template() :: map
  def template,
    do: %{
      loan_products: [],
      definitions: for(c <- Categories.list(), do: %{category_id: c.id, category_name: c.name}),
      accounts: GLAccounts.list(disabled: false, usage: 1)
    }

  defp definitions(criteria_id) do
    from(d in "m_provisioning_criteria_definition",
      left_join: l in "acc_gl_account",
      on: l.id == d.liability_account,
      left_join: e in "acc_gl_account",
      on: e.id == d.expense_account,
      left_join: c in "m_provision_category",
      on: c.id == d.category_id,
      where: d.criteria_id == ^criteria_id,
      order_by: d.id,
      select: %{
        id: d.id,
        category_id: d.category_id,
        category_name: c.category_name,
        min_age: d.min_age,
        max_age: d.max_age,
        percentage: d.provision_percentage,
        liability_account: d.liability_account,
        liability_code: l.gl_code,
        liability_name: l.name,
        expense_account: d.expense_account,
        expense_code: e.gl_code,
        expense_name: e.name
      }
    )
    |> TenantRepo.all()
  end

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.provisioning.criteria.id.invalid",
        "Provisioning Criteria with identifier #{id} does not exist",
        [id]
      )
end
