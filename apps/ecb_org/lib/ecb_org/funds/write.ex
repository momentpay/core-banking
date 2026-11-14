defmodule ECBOrg.Funds.Write do
  @moduledoc """
  Creating and changing funds (`m_fund`), following Fineract's fund service. Runs inside a command's
  transaction and raises Fineract's errors.
  """
  import Ecto.Query

  alias ECBOrg.Funds
  alias ECBPlatform.Changes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.{Integrity, Params, TenantRepo, Validation}

  @doc "Creates the fund `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    name = Params.string(params, "name")
    external_id = Params.string(params, "externalId")

    Validation.new("fund")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("externalId", external_id)
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    {1, [%{id: id}]} =
      guard(name, external_id, fn ->
        TenantRepo.insert_all(
          "m_fund",
          [%{name: String.trim(name), external_id: external_id}],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id)
  end

  @doc "Changes fund `id`. The result lists what changed."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    validate_for_update!(params)

    fund = Funds.fetch!(id)

    changes =
      Changes.new()
      |> Changes.text(params, "name", :name, fund.name)
      |> Changes.text(params, "externalId", :external_id, fund.external_id)

    unless Changes.empty?(changes) do
      guard(Params.string(params, "name"), Params.string(params, "externalId"), fn ->
        TenantRepo.update_all(from(f in "m_fund", where: f.id == ^id), set: Changes.set(changes))
      end)
    end

    Result.new(resource_id: id, changes: Changes.public(changes))
  end

  defp validate_for_update!(params) do
    validation = Validation.new("fund")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank()
          |> Validation.max_length(100),
        else: validation

    validation =
      if Params.exists?(params, "externalId"),
        do:
          validation
          |> Validation.param("externalId", Params.string(params, "externalId"))
          |> Validation.max_length(100),
        else: validation

    Validation.raise_if_errors!(validation)
  end

  defp guard(name, external_id, fun) do
    Integrity.translate(
      fun,
      %{
        "m_fund_external_id_key" =>
          {"error.msg.fund.duplicate.externalId",
           "A fund with external id '#{external_id}' already exists", "externalId",
           [external_id]},
        "m_fund_name_key" =>
          {"error.msg.fund.duplicate.name", "A fund with name '#{name}' already exists", "name",
           [name]}
      },
      {"error.msg.fund.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end
end
