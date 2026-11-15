defmodule ECBLedger.FinancialActivities do
  @moduledoc """
  The mapping of the organisation's financial activities (cash at the main vault, asset transfer, fund
  source, ...) to the GL account each posts to (`acc_gl_financial_activity_account`), read side, following
  Fineract's `FinancialActivityAccountReadPlatformServiceImpl`.

  There is at most one mapping per activity, and the account has to be of the type the activity belongs to.
  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBLedger.GLAccounts
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.TenantRepo

  # id, name, type of the GL account it maps to
  @activities [
    {100, "assetTransfer", 1},
    {200, "liabilityTransfer", 2},
    {101, "cashAtMainVault", 1},
    {102, "cashAtTeller", 1},
    {300, "openingBalancesTransferContra", 3},
    {103, "fundSource", 1},
    {201, "payableDividends", 2}
  ]

  @doc "The financial activities as `%{id, name, mapped_type}` (`mapped_type` is the GL type option)."
  @spec activities() :: [map]
  def activities do
    for {id, name, type} <- @activities,
        do: %{id: id, name: name, mapped_type: GLAccounts.type_option(type)}
  end

  @doc "One activity by id, or `nil`."
  @spec activity(term) :: map | nil
  def activity(id), do: Enum.find(activities(), &(&1.id == id))

  @doc "The activity ids a new mapping may use (all of them)."
  @spec creatable_ids() :: [integer]
  def creatable_ids, do: for({id, _, _} <- @activities, do: id)

  @doc """
  The activity ids a mapping may be *changed* to. Fineract leaves the two cash activities out here, so a
  mapping cannot be moved onto them (they can only be created).
  """
  @spec updatable_ids() :: [integer]
  def updatable_ids, do: creatable_ids() -- [101, 102]

  @doc "Every mapping, in the order of the account they point at."
  @spec list() :: [map]
  def list do
    base()
    |> order_by([faa, gl], asc: gl.id, asc: faa.id)
    |> TenantRepo.all()
    |> Enum.map(&finish/1)
  end

  @doc "One mapping, or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    case base() |> where([faa], faa.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "Like `get/1` but raises the error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, mapping} -> mapping
      {:error, error} -> raise error
    end
  end

  @doc """
  The accounts a mapping can point at, by type: `%{asset: [...], liability: [...], ...}` with enabled
  detail accounts only; a type without any is left out.
  """
  @spec account_options() :: %{atom => [map]}
  def account_options do
    for {type, key} <- [
          {1, :asset},
          {2, :liability},
          {3, :equity},
          {4, :income},
          {5, :expense}
        ],
        accounts = GLAccounts.list(type: type, usage: 1, disabled: false),
        accounts != [],
        into: %{},
        do: {key, accounts}
  end

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.financialActivityAccount.not.found",
        "Financial Activity account with Id #{id} does not exist",
        [id]
      )

  defp base do
    from faa in "acc_gl_financial_activity_account",
      join: gl in "acc_gl_account",
      on: gl.id == faa.gl_account_id,
      select: %{
        id: faa.id,
        activity_id: faa.financial_activity_type,
        account_id: gl.id,
        account_name: gl.name,
        account_code: gl.gl_code
      }
  end

  defp finish(row) do
    %{
      id: row.id,
      activity: activity(row.activity_id),
      account: %{id: row.account_id, name: row.account_name, gl_code: row.account_code}
    }
  end
end
