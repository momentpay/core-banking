defmodule ECBParty.Clients do
  @moduledoc """
  Clients (`m_client`), the read side, following Fineract's `ClientReadPlatformServiceImpl`.

  A user sees the clients of their own office and the offices below it (and clients being transferred to
  such an office). Rows come back as maps with the same names as the columns, joined with what a client
  list shows (office, staff, code values, who submitted, activated and closed it). Must run inside a
  tenant scope.
  """
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @pending 100
  @active 300
  @transfer_in_progress 303
  @transfer_on_hold 304
  @closed 600
  @rejected 700
  @withdrawn 800

  @statuses [
    {@pending, "clientStatusType.pending", "Pending"},
    {@active, "clientStatusType.active", "Active"},
    {@transfer_in_progress, "clientStatusType.transfer.in.progress", "Transfer in progress"},
    {@transfer_on_hold, "clientStatusType.transfer.on.hold", "Transfer on hold"},
    {@closed, "clientStatusType.closed", "Closed"},
    {@rejected, "clientStatusType.rejected", "Rejected"},
    {@withdrawn, "clientStatusType.withdraw", "Withdrawn"}
  ]

  @legal_forms [
    {1, "legalFormType.person", "Person"},
    {2, "legalFormType.entity", "Entity"}
  ]

  @doc "The status values: `:pending`, `:active`, `:closed`, `:rejected` and `:withdrawn` as numbers."
  @spec status(atom) :: integer
  def status(:pending), do: @pending
  def status(:active), do: @active
  def status(:closed), do: @closed
  def status(:rejected), do: @rejected
  def status(:withdrawn), do: @withdrawn
  def status(:transfer_in_progress), do: @transfer_in_progress
  def status(:transfer_on_hold), do: @transfer_on_hold

  @doc "A status number as `{id, code, value}` (an unknown number is the invalid status)."
  @spec status_option(integer) :: map
  def status_option(id) do
    case List.keyfind(@statuses, id, 0) do
      {id, code, value} -> %{id: id, code: code, value: value}
      nil -> %{id: 0, code: "clientStatusType.invalid", value: "Invalid"}
    end
  end

  @doc "The status named in a `?status=` filter (case does not matter), or `nil` when there is no such status."
  @spec status_named(String.t()) :: integer | nil
  def status_named(text) do
    wanted = String.downcase(text)

    names = %{
      "pending" => @pending,
      "active" => @active,
      "transfer_in_progress" => @transfer_in_progress,
      "transfer_on_hold" => @transfer_on_hold,
      "closed" => @closed,
      "rejected" => @rejected,
      "withdrawn" => @withdrawn
    }

    names[wanted]
  end

  @doc "A legal form number as `{id, code, value}`, or `nil`."
  @spec legal_form_option(integer | nil) :: map | nil
  def legal_form_option(nil), do: nil

  def legal_form_option(id) do
    case List.keyfind(@legal_forms, id, 0) do
      {id, code, value} -> %{id: id, code: code, value: value}
      nil -> nil
    end
  end

  @doc "Both legal forms, as options."
  @spec legal_form_options() :: [map]
  def legal_form_options,
    do: Enum.map(@legal_forms, fn {id, code, value} -> %{id: id, code: code, value: value} end)

  @select """
  c.id, c.account_no, c.external_id, c.status_enum, c.sub_status,
  cvsub.code_value AS sub_status_value, cvsub.code_description AS sub_status_desc,
  c.office_id, o.name AS office_name, c.transfer_to_office_id, tro.name AS transfer_to_office_name,
  c.firstname, c.middlename, c.lastname, c.fullname, c.display_name, c.mobile_no, c.is_staff,
  c.email_address, c.date_of_birth, c.gender_cv_id AS gender_id, cvg.code_value AS gender_value,
  c.client_type_cv_id AS client_type_id, cvt.code_value AS client_type_value,
  c.client_classification_cv_id AS classification_id, cvc.code_value AS classification_value,
  c.legal_form_enum, c.submittedon_date AS submitted_on, c.created_by AS submitted_by_id,
  sbu.username AS submitted_by_username, sbu.firstname AS submitted_by_firstname,
  sbu.lastname AS submitted_by_lastname, c.closedon_date AS closed_on, c.closedon_userid AS closed_by_id,
  clu.username AS closed_by_username, clu.firstname AS closed_by_firstname,
  clu.lastname AS closed_by_lastname, c.activatedon_userid AS activated_by_id,
  acu.username AS activated_by_username, acu.firstname AS activated_by_firstname,
  acu.lastname AS activated_by_lastname,
  cnp.id AS non_person_id, cnp.constitution_cv_id AS constitution_id, cvco.code_value AS constitution_value,
  cnp.incorp_no, cnp.incorp_validity_till, cnp.main_business_line_cv_id AS main_business_line_id,
  cvml.code_value AS main_business_line_value, cnp.remarks,
  c.activation_date, c.image_id, c.staff_id, s.display_name AS staff_name,
  c.default_savings_product AS savings_product_id, c.default_savings_account AS savings_account_id,
  c.proposed_transfer_date
  """

  @from """
  FROM m_client c
  JOIN m_office o ON o.id = c.office_id
  LEFT JOIN m_client_non_person cnp ON cnp.client_id = c.id
  LEFT JOIN m_staff s ON s.id = c.staff_id
  LEFT JOIN m_office tro ON tro.id = c.transfer_to_office_id
  LEFT JOIN m_appuser sbu ON sbu.id = c.created_by
  LEFT JOIN m_appuser acu ON acu.id = c.activatedon_userid
  LEFT JOIN m_appuser clu ON clu.id = c.closedon_userid
  LEFT JOIN m_code_value cvg ON cvg.id = c.gender_cv_id
  LEFT JOIN m_code_value cvt ON cvt.id = c.client_type_cv_id
  LEFT JOIN m_code_value cvc ON cvc.id = c.client_classification_cv_id
  LEFT JOIN m_code_value cvsub ON cvsub.id = c.sub_status
  LEFT JOIN m_code_value cvco ON cvco.id = cnp.constitution_cv_id
  LEFT JOIN m_code_value cvml ON cvml.id = cnp.main_business_line_cv_id
  """

  @orderings %{
    "id" => "c.id",
    "displayName" => "c.display_name",
    "officeName" => "o.name",
    "accountNo" => "c.account_no",
    "officeId" => "c.office_id"
  }

  @doc """
  The clients a user can see, filtered. Options (all optional): `:office_id`, `:external_id`,
  `:display_name`, `:firstname`, `:lastname`, `:status` (a status number), `:hierarchy`, `:orphans_only`,
  `:legal_form`, `:staff_id`, `:order_by`, `:sort_order` (`"ASC"` or `"DESC"`), `:limit` and `:offset`.
  Answers the page's rows and how many clients matched before paging.
  """
  @spec list(User.t(), keyword) :: %{total: non_neg_integer, items: [map]}
  def list(%User{} = user, opts \\ []) do
    pattern = ECBOrg.Offices.user_hierarchy_pattern(user)
    {criteria, params} = criteria(opts, [pattern, pattern])

    where =
      "WHERE (o.hierarchy LIKE $1 OR tro.hierarchy LIKE $2)" <>
        Enum.map_join(criteria, "", &(" AND " <> &1))

    total = TenantRepo.query!("SELECT count(*) " <> @from <> where, params).rows |> hd() |> hd()

    sql = "SELECT " <> @select <> @from <> where <> order(opts) <> paging(opts)
    %{total: total, items: rows(TenantRepo.query!(sql, params))}
  end

  defp criteria(opts, params) do
    [
      {:office_id, "c.office_id = ", & &1},
      {:external_id, "c.external_id LIKE ", & &1},
      {:display_name, "c.display_name LIKE ", &("%" <> &1 <> "%")},
      {:firstname, "c.firstname LIKE ", & &1},
      {:lastname, "c.lastname LIKE ", & &1},
      {:status, "c.status_enum = ", & &1},
      {:hierarchy, "o.hierarchy LIKE ", &(&1 <> "%")},
      {:legal_form, "c.legal_form_enum = ", & &1},
      {:staff_id, "c.staff_id = ", & &1}
    ]
    |> Enum.reduce({[], params}, fn {key, sql, convert}, {parts, params} ->
      case Keyword.get(opts, key) do
        nil ->
          {parts, params}

        value ->
          params = params ++ [convert.(value)]
          {parts ++ ["#{sql}$#{length(params)}"], params}
      end
    end)
    |> orphans(opts)
  end

  # No groups exist yet, so every client is an orphan.
  defp orphans(result, _opts), do: result

  defp order(opts) do
    case Keyword.get(opts, :order_by) do
      nil ->
        " ORDER BY c.id"

      field ->
        direction =
          if String.upcase(Keyword.get(opts, :sort_order) || "") == "DESC", do: " DESC", else: ""

        " ORDER BY " <> Map.fetch!(@orderings, field) <> direction
    end
  end

  defp paging(opts) do
    case {Keyword.get(opts, :limit), Keyword.get(opts, :offset)} do
      {nil, _} -> ""
      {limit, nil} -> " LIMIT #{limit}"
      {limit, offset} -> " LIMIT #{limit} OFFSET #{offset}"
    end
  end

  @doc "True when `field` can be used to order the list."
  @spec orderable?(String.t()) :: boolean
  def orderable?(field), do: Map.has_key?(@orderings, field)

  @doc """
  One client by id for a read: it must be in the user's branch of the tree. Not found is Fineract's
  `error.msg.client.not.found.with.client.id`.
  """
  @spec get(User.t(), integer) :: {:ok, map} | {:error, Exception.t()}
  def get(%User{} = user, id) do
    pattern = ECBOrg.Offices.user_hierarchy_pattern(user)

    sql =
      "SELECT " <>
        @select <>
        @from <> "WHERE c.id = $1 AND (o.hierarchy LIKE $2 OR tro.hierarchy LIKE $2)"

    case rows(TenantRepo.query!(sql, [id, pattern])) do
      [row] ->
        {:ok, row}

      [] ->
        {:error,
         ResourceNotFound.new(
           "error.msg.client.not.found.with.client.id",
           "Client not found with valuer #{id}.",
           [to_string(id)]
         )}
    end
  end

  @doc "A client by id for a write, whoever's it is; or `{:error, ResourceNotFound}`."
  @spec find(integer) :: {:ok, map} | {:error, Exception.t()}
  def find(id) do
    sql = "SELECT " <> @select <> @from <> "WHERE c.id = $1"

    case rows(TenantRepo.query!(sql, [id])) do
      [row] -> {:ok, row}
      [] -> {:error, not_found(id)}
    end
  end

  @doc "Like `find/1` but raises."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case find(id) do
      {:ok, row} -> row
      {:error, error} -> raise error
    end
  end

  @doc "The id of the client with this external id, or `nil`."
  @spec id_by_external_id(String.t()) :: integer | nil
  def id_by_external_id(external_id) do
    case TenantRepo.query!("SELECT id FROM m_client WHERE external_id = $1", [external_id]).rows do
      [[id] | _] -> id
      [] -> nil
    end
  end

  @doc "The not-found error for writes."
  @spec not_found(term) :: Exception.t()
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.client.id.invalid",
        "Client with identifier #{id} does not exist",
        [id]
      )

  @doc "The date a transfer of the client was proposed for, or `nil`."
  @spec proposed_transfer_date(integer) :: Date.t() | nil
  def proposed_transfer_date(id) do
    case TenantRepo.query!("SELECT proposed_transfer_date FROM m_client WHERE id = $1", [id]).rows do
      [[date]] -> date
      _ -> nil
    end
  end

  defp rows(%{columns: columns, rows: rows}) do
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end
end
