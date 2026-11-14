defmodule ECBApiFineract.Resources.Staff do
  @moduledoc """
  `/v1/staff`: list, one staff member, create and update.

  The list takes `officeId`, `status` (`active` by default, `inactive` or `all`) and `loanOfficersOnly`.
  As Fineract does, a staff member carries the fixed text `dateFormat` beside the joining date, which is
  written as `yyyy-MM-dd`.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.Staff

  @date_format "dd MMMM yyyy"

  @doc "`GET /staff`"
  def index(conn) do
    params = conn.query_params

    Read.respond(conn, "STAFF", fn ->
      opts = [
        office_id: Read.int_param(params, "officeId"),
        loan_officers_only: params["loanOfficersOnly"] == "true",
        status: params["status"]
      ]

      for s <- Staff.list(conn.assigns.current_user, opts), do: serialize(s)
    end)
  end

  @doc "`GET /staff/:id`"
  def show(conn, raw_id) do
    Read.respond(conn, "STAFF", fn ->
      with {:ok, id} <- Write.id(raw_id, &not_found/1),
           {:ok, staff} <- Staff.get(id),
           do: serialize(staff)
    end)
  end

  @doc "`POST /staff`"
  def create(conn), do: Write.execute(conn, "STAFF", "CREATE")

  @doc "`PUT /staff/:id`"
  def update(conn, raw_id),
    do: Write.with_id(conn, raw_id, &not_found/1, &Write.execute(conn, "STAFF", "UPDATE", id: &1))

  defp serialize(s) do
    %{
      "id" => s.id,
      "firstname" => s.firstname,
      "lastname" => s.lastname,
      "displayName" => s.display_name,
      "officeId" => s.office_id,
      "officeName" => s.office_name,
      "isLoanOfficer" => s.is_loan_officer,
      "externalId" => s.external_id,
      "mobileNo" => s.mobile_no,
      "isActive" => s.is_active,
      "joiningDate" => s.joining_date && Date.to_iso8601(s.joining_date),
      "dateFormat" => @date_format
    }
  end

  defp not_found(raw),
    do:
      ECBPlatform.Errors.ResourceNotFound.new(
        "error.msg.staff.id.invalid",
        "Staff with identifier #{raw} does not exist",
        [raw]
      )
end
