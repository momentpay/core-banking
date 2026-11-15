defmodule ECBApiFineract.Resources.Clients do
  @moduledoc """
  `/v1/clients`: the customer master. List (with filters and paging), one client (by id or external id,
  with `?template=true` for the form lists), the template, create, update, delete and the life-cycle
  commands that share the client's path (`?command=activate`, `close`, `reject`, `withdraw`,
  `reactivate`, `undoRejection`, `undoWithdrawal`, `assignStaff`, `unassignStaff`).

  Reading needs `READ_CLIENT`; each write needs `<ACTION>_CLIENT`. A client's JSON is built two ways in
  Fineract, and both are followed: the list shows the full timeline and empty code values as `{}`, a
  single client shows only what is set.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.Errors.InvalidOrdering
  alias ECBParty.Clients
  alias ECBParty.Clients.Options
  alias ECBPlatform.Errors.{PlatformApiDataValidation, UnrecognizedQueryParameter}

  @resource "CLIENT"

  @commands %{
    "activate" => "ACTIVATE",
    "assignStaff" => "ASSIGNSTAFF",
    "unassignStaff" => "UNASSIGNSTAFF",
    "close" => "CLOSE",
    "reject" => "REJECT",
    "withdraw" => "WITHDRAW",
    "reactivate" => "REACTIVATE",
    "undoRejection" => "UNDOREJECT",
    "undoWithdrawal" => "UNDOWITHDRAWAL"
  }

  # Commands that exist in Fineract and are built later (transfers between offices, the default savings account).
  @not_built ~w(proposeTransfer proposeAndAcceptTransfer withdrawTransfer acceptTransfer rejectTransfer
                updateSavingsAccount)

  # The names `fields` can choose between (Fineract's response parameters for a client).
  @choosable ~w(id accountNo externalId status active activationDate firstname middlename lastname
                fullname displayName mobileNo emailAddress officeId officeName transferToOfficeId
                transferToOfficeName hierarchy imageId imagePresent staffId staffName timeline groups
                officeOptions staffOptions dateOfBirth gender clientType clientClassification
                legalForm clientNonPersonDetails isStaff)

  @order_error "invalid input for profile 'client-order-by': does not match any permitted pattern"

  # --- reads ----------------------------------------------------------------------------------

  @doc "`GET /clients`"
  def index(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      with {:ok, opts} <- list_options(q) do
        %{total: total, items: items} = Clients.list(conn.assigns.current_user, opts)

        %{"totalFilteredRecords" => total, "pageItems" => Enum.map(items, &list_json/1)}
        |> only_fields(q)
      end
    end)
  end

  @doc "`GET /clients/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id -> show_by(conn, {:id, id}) end)
  end

  @doc "`GET /clients/external-id/:external_id`"
  def show_by_external_id(conn, external_id), do: show_by(conn, {:external_id, external_id})

  defp show_by(conn, key) do
    q = conn.query_params
    user = conn.assigns.current_user

    Read.respond(conn, @resource, fn ->
      with {:ok, id} <- resolve(key),
           {:ok, row} <- Clients.get(user, id) do
        row |> detail_json() |> with_template(row, user, q) |> only_fields(q)
      end
    end)
  end

  defp with_template(body, row, user, %{"template" => "true"} = q),
    do: with_template(body, row, user, q["staffInSelectedOfficeOnly"] == "true")

  defp with_template(body, _row, _user, q) when is_map(q), do: body

  defp with_template(body, row, user, staff_office_only?) do
    body
    |> Map.delete("clientCollateralManagements")
    |> Map.merge(options(user, row.office_id, staff_office_only?))
  end

  @doc "`GET /clients/template`"
  def template(conn) do
    q = conn.query_params
    user = conn.assigns.current_user

    Read.respond(conn, @resource, fn ->
      with {:ok, office_id} <- number(q, "officeId") do
        user |> template_for(q, office_id) |> only_fields(q)
      end
    end)
  end

  defp template_for(user, q, office_id) do
    case q["commandParam"] do
      command when command in ["close", "acceptTransfer"] ->
        narrations("ClientClosureReason")

      "reject" ->
        narrations("ClientRejectReason")

      "withdraw" ->
        narrations("ClientWithdrawReason")

      _ ->
        template_json(user, office_id || user.office_id, q["staffInSelectedOfficeOnly"] == "true")
    end
  end

  @doc "`GET /clients/:id/accounts` (and by external id): the accounts a client holds."
  def accounts(conn, key) do
    user = conn.assigns.current_user

    Read.respond(conn, @resource, fn ->
      with {:ok, id} <- resolve(key),
           {:ok, _row} <- Clients.get(user, id) do
        # loans, savings and shares are added to this answer as those modules arrive
        %{
          "groupLoanIndividualMonitoringAccounts" => [],
          "guarantorAccounts" => [],
          "workingCapitalLoanAccounts" => []
        }
      end
    end)
  end

  @doc "`GET /clients/:id/obligeedetails`"
  def obligee_details(conn, key) do
    # no loan guarantees exist yet
    Read.respond(conn, @resource, fn -> with {:ok, _id} <- resolve(key), do: [] end)
  end

  @doc "`GET /clients/:id/transferproposaldate`: the date a transfer was proposed for, or nothing (204)."
  def transfer_proposal_date(conn, key) do
    with :ok <-
           ECBPlatform.Security.validate_has_read_permission(conn.assigns.current_user, @resource),
         {:ok, id} <- resolve(key) do
      case Clients.proposed_transfer_date(id) do
        nil -> Plug.Conn.send_resp(conn, 204, "")
        date -> ECBApiFineract.Response.json(conn, 200, date)
      end
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  # --- writes ---------------------------------------------------------------------------------

  @doc "`POST /clients`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /clients/:id` (or by external id)"
  def update(conn, key), do: with_id(conn, key, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /clients/:id` (or by external id)"
  def delete(conn, key), do: with_id(conn, key, &Write.execute(conn, @resource, "DELETE", id: &1))

  @doc "`POST /clients/:id?command=...` (or by external id)"
  def command(conn, key) do
    with_id(conn, key, fn id ->
      command = conn.query_params["command"]

      case Map.fetch(@commands, command) do
        {:ok, action} ->
          Write.execute(conn, @resource, action, id: id)

        :error when command in @not_built ->
          Errors.not_implemented(conn, conn.method, conn.request_path)

        :error ->
          Errors.render(conn, %UnrecognizedQueryParameter{
            name: "command",
            value: conn.query_params["command"],
            allowed:
              ~w(activate unassignStaff assignStaff close proposeTransfer withdrawTransfer
                        acceptTransfer rejectTransfer updateSavingsAccount reject withdraw reactivate)
          })
      end
    end)
  end

  # The id a path names: a number, or (for the external-id paths) the client with that external id.
  defp with_id(conn, {:external_id, external_id}, fun) do
    case resolve({:external_id, external_id}) do
      {:ok, id} -> fun.(id)
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp with_id(conn, raw_id, fun), do: Write.with_path_id(conn, raw_id, fun)

  defp resolve({:id, id}), do: {:ok, id}
  defp resolve(raw) when is_binary(raw), do: Write.path_id(raw)

  defp resolve({:external_id, external_id}) do
    case Clients.id_by_external_id(external_id) do
      nil -> {:error, Clients.not_found(external_id)}
      id -> {:ok, id}
    end
  end

  # --- query parameters -----------------------------------------------------------------------

  defp list_options(q) do
    with {:ok, office_id} <- number(q, "officeId"),
         {:ok, offset} <- number(q, "offset"),
         {:ok, limit} <- number(q, "limit"),
         {:ok, legal_form} <- number(q, "legalForm"),
         {:ok, staff_id} <- number(q, "staffId"),
         {:ok, status} <- status(q["status"]),
         :ok <- check_order(q) do
      {:ok,
       [
         office_id: office_id,
         external_id: q["externalId"],
         display_name: q["displayName"],
         firstname: q["firstName"],
         lastname: q["lastName"],
         status: status,
         hierarchy: q["underHierarchy"],
         legal_form: legal_form,
         staff_id: staff_id,
         order_by: blank_to_nil(q["orderBy"]),
         sort_order: q["sortOrder"],
         limit: limit,
         offset: offset
       ]
       |> Enum.reject(fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp status(nil), do: {:ok, nil}

  defp status(text) do
    case Clients.status_named(text) do
      nil ->
        # Fineract builds this error with its arguments in the wrong places: the parameter name shows as the
        # text for people and the value as the parameter name
        {:error,
         %PlatformApiDataValidation{
           errors: [
             %{
               code: "validation.msg.client.status.value.is.not.supported",
               developer_message: "The Status value '#{text}' is not supported.",
               default_message: "status",
               parameter: text,
               args: []
             }
           ]
         }}

      status ->
        {:ok, status}
    end
  end

  defp check_order(q) do
    order_by = blank_to_nil(q["orderBy"])
    sort_order = q["sortOrder"]

    cond do
      order_by == nil -> :ok
      not Clients.orderable?(order_by) -> {:error, %InvalidOrdering{detail: @order_error}}
      sort_order in [nil, ""] -> :ok
      String.upcase(sort_order) in ["ASC", "DESC"] -> :ok
      true -> {:error, %InvalidOrdering{detail: "invalid sortOrder value '#{sort_order}'"}}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # A numeric query parameter; text that is not a number is the web container's plain 404.
  defp number(q, key) do
    case q[key] do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      text -> parse_number(text)
    end
  end

  defp parse_number(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, %Errors.PathNotFound{}}
    end
  end

  # --- JSON -----------------------------------------------------------------------------------

  defp status_json(id), do: id |> Clients.status_option() |> Read.option()

  defp code_value(nil, _name), do: nil
  defp code_value(id, name), do: %{"id" => id, "name" => name}

  defp user_name(username, first, last),
    do: %{username: username, firstname: first, lastname: last}

  # one client as the single read shows it
  defp detail_json(r) do
    %{
      "id" => r.id,
      "accountNo" => r.account_no,
      "externalId" => blank_to_nil(r.external_id),
      "status" => status_json(r.status_enum),
      "active" => r.status_enum == Clients.status(:active),
      "activationDate" => r.activation_date,
      "firstname" => r.firstname,
      "middlename" => r.middlename,
      "lastname" => r.lastname,
      "fullname" => r.fullname,
      "displayName" => r.display_name,
      "mobileNo" => r.mobile_no,
      "emailAddress" => r.email_address,
      "dateOfBirth" => r.date_of_birth,
      "gender" => code_value(r.gender_id, r.gender_value),
      "clientType" => code_value(r.client_type_id, r.client_type_value),
      "clientClassification" => code_value(r.classification_id, r.classification_value),
      "isStaff" => r.is_staff,
      "officeId" => r.office_id,
      "officeName" => r.office_name,
      "transferToOfficeId" => r.transfer_to_office_id,
      "transferToOfficeName" => r.transfer_to_office_name,
      "imageId" => r.image_id,
      "staffId" => r.staff_id,
      "staffName" => r.staff_name,
      "timeline" => detail_timeline(r),
      "savingsProductId" => r.savings_product_id,
      # Fineract fills this with the client's own id
      "savingsProductName" => Integer.to_string(r.id),
      "savingsAccountId" => r.savings_account_id,
      "legalForm" => legal_form_json(r.legal_form_enum),
      "clientCollateralManagements" => [],
      "groups" => []
    }
    |> put_non_person(r, :detail)
  end

  defp legal_form_json(form),
    do: form |> Clients.legal_form_option() |> then(&(&1 && Read.option(&1)))

  # the single read gives a timeline by state: closed, active, or just the submission
  defp detail_timeline(r) do
    cond do
      r.status_enum == Clients.status(:closed) ->
        %{"submittedOnDate" => r.submitted_on, "activatedOnDate" => r.activation_date}
        |> Map.merge(
          by(
            "activatedBy",
            user_name(r.activated_by_username, r.activated_by_firstname, r.activated_by_lastname)
          )
        )
        |> Map.put("closedOnDate", r.closed_on)
        |> Map.merge(
          by(
            "closedBy",
            user_name(r.closed_by_username, r.closed_by_firstname, r.closed_by_lastname)
          )
        )

      r.status_enum == Clients.status(:active) ->
        %{"submittedOnDate" => r.submitted_on, "activatedOnDate" => r.activation_date}
        |> Map.merge(
          by(
            "activatedBy",
            user_name(r.activated_by_username, r.activated_by_firstname, r.activated_by_lastname)
          )
        )

      true ->
        %{"submittedOnDate" => r.submitted_on}
    end
  end

  defp by(prefix, %{username: u, firstname: f, lastname: l}),
    do: %{(prefix <> "Username") => u, (prefix <> "Firstname") => f, (prefix <> "Lastname") => l}

  # one client as the list shows it
  defp list_json(r) do
    %{
      "id" => r.id,
      "accountNo" => r.account_no,
      "externalId" => blank_to_nil(r.external_id),
      "status" => status_json(r.status_enum),
      "subStatus" => %{
        "id" => r.sub_status,
        "name" => r.sub_status_value,
        "description" => r.sub_status_desc,
        "active" => false,
        "mandatory" => false
      },
      "active" => r.status_enum == Clients.status(:active),
      "activationDate" => r.activation_date,
      "firstname" => r.firstname,
      "middlename" => r.middlename,
      "lastname" => r.lastname,
      "fullname" => r.fullname,
      "displayName" => r.display_name,
      "mobileNo" => r.mobile_no,
      "emailAddress" => r.email_address,
      "dateOfBirth" => r.date_of_birth,
      "gender" => code_value_or_empty(r.gender_id, r.gender_value),
      "clientType" => code_value_or_empty(r.client_type_id, r.client_type_value),
      "clientClassification" => code_value_or_empty(r.classification_id, r.classification_value),
      "isStaff" => r.is_staff,
      "officeId" => r.office_id,
      "officeName" => r.office_name,
      "transferToOfficeId" => r.transfer_to_office_id,
      "transferToOfficeName" => r.transfer_to_office_name,
      "imageId" => r.image_id,
      "staffId" => r.staff_id,
      "staffName" => r.staff_name,
      "timeline" => list_timeline(r),
      "savingsProductId" => r.savings_product_id,
      "savingsAccountId" => r.savings_account_id,
      "legalForm" => legal_form_json(r.legal_form_enum)
    }
    |> put_non_person(r, :list)
  end

  # an empty code value is shown as `{}` in the list
  defp code_value_or_empty(id, name), do: code_value(id, name) || %{}

  defp list_timeline(r) do
    %{
      "submittedOnDate" => r.submitted_on,
      "activatedOnDate" => r.activation_date,
      "closedOnDate" => r.closed_on
    }
    |> Map.merge(
      by(
        "submittedBy",
        user_name(r.submitted_by_username, r.submitted_by_firstname, r.submitted_by_lastname)
      )
    )
    |> Map.merge(
      by(
        "activatedBy",
        user_name(r.activated_by_username, r.activated_by_firstname, r.activated_by_lastname)
      )
    )
    |> Map.merge(
      by("closedBy", user_name(r.closed_by_username, r.closed_by_firstname, r.closed_by_lastname))
    )
  end

  # the details of an entity client: always in the list, only when they exist in the single read
  defp put_non_person(body, r, :list),
    do: Map.put(body, "clientNonPersonDetails", non_person_json(r, &code_value_or_empty(&1, &2)))

  defp put_non_person(body, %{non_person_id: nil}, :detail), do: body

  defp put_non_person(body, r, :detail),
    do: Map.put(body, "clientNonPersonDetails", non_person_json(r, &code_value/2))

  defp non_person_json(r, code) do
    %{
      "constitution" => code.(r.constitution_id, r.constitution_value),
      "incorpNumber" => r.incorp_no,
      "incorpValidityTillDate" => r.incorp_validity_till,
      "mainBusinessLine" => code.(r.main_business_line_id, r.main_business_line_value),
      "remarks" => r.remarks
    }
  end

  # --- templates ------------------------------------------------------------------------------

  defp narrations(code_name),
    do: %{"isStaff" => false, "narrations" => Enum.map(Options.code_values(code_name), &option/1)}

  defp template_json(user, office_id, staff_office_only?) do
    %{
      "activationDate" => ECBPlatform.BusinessDate.current(),
      "isStaff" => false,
      "officeId" => office_id,
      "isAddressEnabled" => ECBPlatform.Configuration.enabled?("enable-address"),
      "address" => [nil]
    }
    |> Map.merge(options(user, office_id, staff_office_only?))
  end

  defp options(user, office_id, staff_office_only?) do
    %{
      "officeOptions" => Enum.map(Options.offices(user), &office_option/1),
      "staffOptions" => staff_options(user, office_id, staff_office_only?),
      "savingProductOptions" => Enum.map(Options.savings_products(), &saving_product/1),
      "genderOptions" => values("Gender"),
      "clientTypeOptions" => values("ClientType"),
      "clientClassificationOptions" => values("ClientClassification"),
      "clientNonPersonConstitutionOptions" => values("Constitution"),
      "clientNonPersonMainBusinessLineOptions" => values("Main Business Line"),
      "clientLegalFormOptions" => Enum.map(Clients.legal_form_options(), &Read.option/1),
      "familyMemberOptions" => %{
        "relationshipIdOptions" => values("RELATIONSHIP"),
        "genderIdOptions" => values("Gender"),
        "maritalStatusIdOptions" => values("MARITAL STATUS"),
        "professionIdOptions" => values("PROFESSION")
      }
    }
  end

  defp values(name), do: Enum.map(Options.code_values(name), &option/1)

  defp option(v) do
    %{
      "id" => v.id,
      "name" => v.name,
      "position" => v.position,
      "description" => v.description,
      "active" => v.active,
      "mandatory" => v.mandatory
    }
  end

  defp office_option(o),
    do: %{"id" => o.id, "name" => o.name, "nameDecorated" => o.name_decorated}

  defp saving_product(p), do: %{"id" => p.id, "name" => p.name}

  defp staff_options(user, office_id, office_only?) do
    case Options.staff(user, office_id, office_only?) do
      [] -> nil
      list -> Enum.map(list, &staff_option/1)
    end
  end

  defp staff_option(%{office_id: _} = s) do
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
      "joiningDate" => s.joining_date,
      "dateFormat" => "dd MMMM yyyy"
    }
  end

  defp staff_option(s),
    do: %{"id" => s.id, "displayName" => s.display_name, "dateFormat" => "dd MMMM yyyy"}

  # --- `fields` -------------------------------------------------------------------------------

  # Only the named fields: a name Fineract lets `fields` choose that was not asked for is left out
  # wherever it appears.
  defp only_fields({:error, _} = error, _q), do: error

  defp only_fields(body, q) do
    case q["fields"] do
      fields when is_binary(fields) and fields != "" ->
        wanted = fields |> String.split(",") |> Enum.map(&String.trim/1)
        drop = MapSet.new(@choosable -- wanted)
        filter(body, drop)

      _ ->
        body
    end
  end

  defp filter(%{__struct__: _} = struct, _drop), do: struct

  defp filter(map, drop) when is_map(map),
    do: for({k, v} <- map, not MapSet.member?(drop, k), into: %{}, do: {k, filter(v, drop)})

  defp filter(list, drop) when is_list(list), do: Enum.map(list, &filter(&1, drop))
  defp filter(other, _drop), do: other
end
