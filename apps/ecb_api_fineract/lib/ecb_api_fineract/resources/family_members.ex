defmodule ECBApiFineract.Resources.FamilyMembers do
  @moduledoc """
  `/v1/clients/:client_id/familymembers`: the family of a client. List, one, template, create, update
  and delete. Reading needs `READ_FAMILYMEMBERS`; each write needs `<ACTION>_FAMILYMEMBERS`. The bodies
  are typed: what Fineract's request class does not list is ignored.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBParty.Clients.Options
  alias ECBParty.FamilyMembers

  @resource "FAMILYMEMBERS"

  @doc "`GET /clients/:client_id/familymembers`"
  def index(conn, raw_client_id) do
    Write.with_path_id(conn, raw_client_id, fn client_id ->
      Read.respond(conn, @resource, fn ->
        client_id |> FamilyMembers.list() |> Enum.map(&json/1)
      end)
    end)
  end

  @doc "`GET /clients/:client_id/familymembers/template`"
  def template(conn, raw_client_id) do
    Write.with_path_id(conn, raw_client_id, fn _client_id ->
      Read.respond(conn, @resource, fn ->
        %{
          "relationshipIdOptions" => values("RELATIONSHIP"),
          "genderIdOptions" => values("Gender"),
          "maritalStatusIdOptions" => values("MARITAL STATUS"),
          "professionIdOptions" => values("PROFESSION")
        }
      end)
    end)
  end

  @doc "`GET /clients/:client_id/familymembers/:id`"
  def show(conn, raw_client_id, raw_id) do
    with_ids(conn, raw_client_id, raw_id, fn client_id, id ->
      Read.respond(conn, @resource, fn -> one(client_id, id) end)
    end)
  end

  defp one(client_id, id) do
    with {:ok, row} <- FamilyMembers.get(client_id, id), do: json(row)
  end

  # both ids in the path must be numbers, or the answer is the web container's plain 404
  defp with_ids(conn, raw_client_id, raw_id, fun) do
    Write.with_path_id(conn, raw_client_id, fn client_id ->
      Write.with_path_id(conn, raw_id, &fun.(client_id, &1))
    end)
  end

  @doc "`POST /clients/:client_id/familymembers`"
  def create(conn, raw_client_id),
    do:
      Write.with_path_id(
        conn,
        raw_client_id,
        &Write.execute(conn, @resource, "CREATE", client_id: &1)
      )

  @doc "`PUT /clients/:client_id/familymembers/:id`"
  def update(conn, _raw_client_id, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /clients/:client_id/familymembers/:id`"
  def delete(conn, _raw_client_id, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  defp values(code_name) do
    Enum.map(Options.code_values(code_name), fn v ->
      %{
        "id" => v.id,
        "name" => v.name,
        "position" => v.position,
        "description" => v.description,
        "active" => v.active,
        "mandatory" => v.mandatory
      }
    end)
  end

  defp json(r) do
    %{
      "id" => r.id,
      "clientId" => r.client_id,
      "firstName" => r.first_name,
      "middleName" => r.middle_name,
      "lastName" => r.last_name,
      "qualification" => r.qualification,
      "relationshipId" => r.relationship_id,
      "relationship" => r.relationship,
      "maritalStatusId" => r.marital_status_id || 0,
      "maritalStatus" => r.marital_status,
      "genderId" => r.gender_id || 0,
      "gender" => r.gender,
      "dateOfBirth" => r.date_of_birth && Date.to_iso8601(r.date_of_birth),
      "professionId" => r.profession_id || 0,
      "profession" => r.profession,
      "mobileNumber" => r.mobile_number,
      "age" => r.age || 0,
      "isDependent" => r.is_dependent == true
    }
  end
end
