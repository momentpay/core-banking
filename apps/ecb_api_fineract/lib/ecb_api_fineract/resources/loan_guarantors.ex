defmodule ECBApiFineract.Resources.LoanGuarantors do
  @moduledoc """
  `/loans/{id}/guarantors`: the guarantors of a loan, one of them, the templates for adding one, and adding,
  changing and removing them, after Fineract's `GuarantorsApiResource`.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{LoanProducts, Read, Write}
  alias ECBLoans.{Guarantors, Loans}
  alias ECBPlatform.Errors.ServerError

  @resource "GUARANTOR"

  @doc "`GET /loans/:id/guarantors`"
  def index(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        Loans.fetch!(id)
        id |> Guarantors.list() |> Enum.map(&item/1)
      end)
    end)
  end

  @doc "`GET /loans/:id/guarantors/template`: made for any loan, as Fineract does"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn _id ->
      Read.respond(conn, @resource, fn ->
        Map.merge(
          %{
            "guarantorType" => Guarantors.type_option(1),
            "status" => false,
            "guarantorTypeOptions" => Guarantors.type_options(),
            "allowedClientRelationshipTypes" => LoanProducts.code_values("GuarantorRelationship")
          },
          flags(1)
        )
      end)
    end)
  end

  @doc "`GET /loans/:id/guarantors/accounts/template`: Fineract fails on a loan that is not there"
  def accounts_template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> accounts_template_of(Loans.get(id)) end)
    end)
  end

  defp accounts_template_of(nil), do: {:error, %ServerError{}}

  defp accounts_template_of(_loan),
    do: Map.merge(%{"guarantorType" => Guarantors.type_option(1), "status" => false}, flags(1))

  @doc "`GET /loans/:id/guarantors/:guarantor_id`: one that is not there is a failure of Fineract's"
  def show(conn, raw_id, raw_guarantor_id) do
    with_ids(conn, raw_id, raw_guarantor_id, fn id, guarantor_id ->
      Read.respond(conn, @resource, fn -> one(Guarantors.get(id, guarantor_id)) end)
    end)
  end

  defp one(nil), do: {:error, %ServerError{}}
  defp one(g), do: item(g)

  # the guarantor as Fineract's data class is written: what is not there is left out
  defp item(g) do
    %{
      "id" => g.id,
      "loanId" => g.loan_id,
      "guarantorType" => Guarantors.type_option(g.type),
      "entityId" => g.entity_id || 0,
      "status" => g.active
    }
    |> Map.merge(flags(g.type))
    |> put(
      "clientRelationshipType",
      g.relationship_id && %{"id" => g.relationship_id, "name" => g.relationship_name}
    )
    |> put("firstname", g.firstname)
    |> put("lastname", g.lastname)
    |> put("addressLine1", g.address_line_1)
    |> put("addressLine2", g.address_line_2)
    |> put("city", g.city)
    |> put("state", g.state)
    |> put("zip", g.zip)
    |> put("country", g.country)
    |> put("mobileNumber", g.mobile_number)
    |> put("housePhoneNumber", g.house_phone_number)
    |> put("comment", g.comment)
    |> put("dob", iso(g.dob))
    |> put("officeName", Map.get(g, :office_name))
    |> put("joinedDate", iso(Map.get(g, :joined_date)))
    |> put("externalId", Map.get(g, :external_id))
  end

  defp flags(type) do
    %{
      "externalGuarantor" => type == 3,
      "existingGroup" => type == 4,
      "existingClient" => type == 1,
      "staffMember" => type == 2
    }
  end

  defp iso(nil), do: nil
  defp iso(date), do: Date.to_iso8601(date)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  @doc "`POST /loans/:id/guarantors`"
  def create(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "CREATE", id: &1))

  @doc "`PUT /loans/:id/guarantors/:guarantor_id`"
  def update(conn, raw_id, raw_guarantor_id) do
    with_ids(conn, raw_id, raw_guarantor_id, fn id, guarantor_id ->
      Write.execute(conn, @resource, "UPDATE", id: id, subentity_id: guarantor_id)
    end)
  end

  @doc "`DELETE /loans/:id/guarantors/:guarantor_id?guarantorFundingId=`"
  def delete(conn, raw_id, raw_guarantor_id) do
    with_ids(conn, raw_id, raw_guarantor_id, fn id, guarantor_id ->
      json =
        case Integer.parse(to_string(conn.query_params["guarantorFundingId"])) do
          {funding_id, ""} -> Jason.encode!(%{"guarantorFundingId" => funding_id})
          _ -> nil
        end

      Write.execute(conn, @resource, "DELETE", id: id, subentity_id: guarantor_id, json: json)
    end)
  end

  defp with_ids(conn, raw_id, raw_guarantor_id, fun) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, guarantor_id} <- Write.path_id(raw_guarantor_id) do
      fun.(id, guarantor_id)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end
end
