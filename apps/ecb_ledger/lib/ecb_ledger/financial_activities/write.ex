defmodule ECBLedger.FinancialActivities.Write do
  @moduledoc """
  Creating, changing and deleting financial-activity mappings, following Fineract's
  `FinancialActivityAccountWritePlatformServiceImpl`.

  An activity has at most one mapping and its account must be of the type the activity belongs to (cash
  activities take asset accounts, the liability transfer takes a liability account, and so on). Any kind of
  account with that type will do: a header or disabled account is accepted, as in Fineract. Runs inside a
  command's transaction.
  """
  import Ecto.Query

  alias ECBLedger.{FinancialActivities, GLAccounts}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @unique "acc_gl_financial_activity_account_financial_activity_type_key"

  @doc "Maps the activity in `params` to the account in `params`."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    activity_id = Params.long(params, "financialActivityId")
    account_id = Params.long(params, "glAccountId")

    Validation.new("financialactivityaccount")
    |> Validation.param("financialActivityId", activity_id)
    |> Validation.not_null()
    |> Validation.one_of(FinancialActivities.creatable_ids())
    |> Validation.param("glAccountId", account_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    account = GLAccounts.fetch!(account_id)
    check_type!(activity_id, account)

    {1, [%{id: id}]} =
      guard(activity_id, fn ->
        TenantRepo.insert_all(
          "acc_gl_financial_activity_account",
          [%{gl_account_id: account.id, financial_activity_type: activity_id}],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id)
  end

  @doc "Changes mapping `id`: its account, its activity or both."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    activity_id = Params.long(params, "financialActivityId")
    account_id = Params.long(params, "glAccountId")

    Validation.new("financialactivityaccount")
    |> Validation.param("financialActivityId", activity_id)
    |> Validation.ignore_if_null()
    |> Validation.one_of(FinancialActivities.updatable_ids())
    |> Validation.param("glAccountId", account_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    mapping = FinancialActivities.fetch!(id)
    changes = changes(mapping, activity_id, account_id)

    account =
      if Map.has_key?(changes, "glAccountId"),
        do: GLAccounts.fetch!(account_id),
        else: GLAccounts.fetch!(mapping.account.id)

    unless changes == %{} do
      new_activity = Map.get(changes, "financialActivityId", mapping.activity.id)
      check_type!(new_activity, account)

      guard(new_activity, fn ->
        TenantRepo.update_all(
          from(faa in "acc_gl_financial_activity_account", where: faa.id == ^id),
          set: [gl_account_id: account.id, financial_activity_type: new_activity]
        )
      end)
    end

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  @doc "Deletes mapping `id`."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    FinancialActivities.fetch!(id)

    TenantRepo.delete_all(from(faa in "acc_gl_financial_activity_account", where: faa.id == ^id))
    Result.new(resource_id: id)
  end

  # --- internals ------------------------------------------------------------------------------

  # Only what really differs from the stored mapping counts as a change.
  defp changes(mapping, activity_id, account_id) do
    %{}
    |> put_if_changed("glAccountId", account_id, mapping.account.id)
    |> put_if_changed("financialActivityId", activity_id, mapping.activity.id)
  end

  defp put_if_changed(changes, _key, nil, _existing), do: changes
  defp put_if_changed(changes, _key, same, same), do: changes
  defp put_if_changed(changes, key, new, _existing), do: Map.put(changes, key, new)

  defp check_type!(activity_id, account) do
    activity = FinancialActivities.activity(activity_id)

    if activity.mapped_type.id != account.type_id do
      raise DomainRuleViolation,
        code: "error.msg.financialActivityAccount.invalid",
        message:
          "Financial Activity '#{activity.name}' with Id :#{activity.id}' can only be associated with a " <>
            "Ledger Account of Type #{activity.mapped_type.code} the provided Ledger Account " <>
            "'#{account.name}(#{account.gl_code})'  does not of the required type",
        args: [
          activity.name,
          activity.id,
          activity.mapped_type.code,
          account.name,
          account.gl_code
        ]
    end
  end

  # A second mapping for an activity is a domain rule, not a data-integrity error.
  defp guard(activity_id, fun) do
    fun.()
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :unique_violation, constraint: @unique} ->
          reraise DomainRuleViolation.exception(
                    code: "error.msg.financialActivityAccount.exists",
                    message: "Mapping for activity already exists #{activity_id}",
                    args: [activity_id]
                  ),
                  __STACKTRACE__

        _ ->
          reraise error, __STACKTRACE__
      end
  end
end
