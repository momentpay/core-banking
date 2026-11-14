defmodule ECBLedger.GLAccounts.Write do
  @moduledoc """
  Creating, changing and deleting GL accounts, following Fineract's `GLAccountWritePlatformService`.

  Rules worth knowing: a parent must be a *header* account; an account's tag must come from the code list
  for its type; a detail account that has entries cannot become a header; an account that has entries, is
  mapped to a product or has sub-accounts cannot be deleted; an account mapped to a product cannot be
  disabled. Moving an account moves everything beneath it. Runs inside a command's transaction.
  """
  import Ecto.Query

  alias ECBLedger.GLAccounts
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Integrity, Params, TenantRepo, Validation}

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the account `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    name = Params.string(params, "name")
    gl_code = Params.string(params, "glCode")
    parent_id = Params.long(params, "parentId")
    type = Params.integer(params, "type")
    usage = Params.integer(params, "usage")
    manual = Params.boolean(params, "manualEntriesAllowed")
    tag_id = Params.long(params, "tagId")

    Validation.new("GLAccount")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.max_length(200)
    |> Validation.param("glCode", gl_code)
    |> Validation.not_blank()
    |> Validation.max_length(45)
    |> Validation.param("parentId", parent_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("type", type)
    |> Validation.not_null()
    |> Validation.in_range(1, 5)
    |> Validation.param("usage", usage)
    |> Validation.in_range(1, 2)
    |> Validation.param("description", Params.string(params, "description"))
    |> Validation.max_length(500)
    |> Validation.param("manualEntriesAllowed", manual)
    |> Validation.not_blank()
    |> Validation.param("tagId", tag_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    parent = parent_id && valid_parent!(parent_id)
    tag = tag_id && tag!(tag_id, type)

    {1, [%{id: id}]} =
      guard(gl_code, fn ->
        TenantRepo.insert_all(
          "acc_gl_account",
          [
            %{
              parent_id: parent && parent.id,
              name: String.trim(name),
              gl_code: String.trim(gl_code),
              disabled: Params.boolean(params, "disabled") == true,
              manual_journal_entries_allowed: manual,
              classification_enum: type,
              account_usage: usage || 1,
              description: Params.string(params, "description"),
              tag_id: tag
            }
          ],
          returning: [:id]
        )
      end)

    set_hierarchy!(id, parent)
    Result.new(resource_id: id)
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes account `id`. The result lists what changed (no `changes` at all when nothing did)."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    validate_for_update!(params)

    if Params.boolean(params, "disabled") == true and GLAccounts.mapped_to_product?(id),
      do:
        raise(DomainRuleViolation,
          code: "error.msg.glaccount.attached.to.product",
          message: "General Ledger Account is already attached to product.",
          args: []
        )

    parent_id = Params.long(params, "parentId")

    if parent_id == id,
      do:
        raise(DomainRuleViolation,
          code: "error.msg.glaccount.id.and.parentid.must.not.same",
          message: "parentId:#{parent_id}, id#{id} should not be same",
          args: [id, parent_id]
        )

    account = GLAccounts.fetch!(id)
    changes = changes(params, account)

    parent = if Map.has_key?(changes, "parentId"), do: valid_parent!(parent_id)
    tag = tag_change!(changes, params, account)
    usage_to_header!(changes, account)

    set =
      for {key, column, value} <- stored(changes, parent, tag),
          Map.has_key?(changes, key),
          do: {column, value}

    unless set == [] do
      guard(Params.string(params, "glCode"), fn ->
        TenantRepo.update_all(from(gl in "acc_gl_account", where: gl.id == ^id), set: set)
      end)
    end

    if parent, do: move!(account, parent)

    Result.new(resource_id: id, changes: if(changes == %{}, do: nil, else: changes))
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes account `id`."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    account = GLAccounts.fetch!(id)

    cond do
      account.usage_id == 2 and GLAccounts.children?(id) ->
        refuse!(
          "error.msg.glaccount.glcode.invalid.delete.has.children",
          "Cannot delete this Header GL Account without first deleting or reassigning its children",
          id
        )

      GLAccounts.posted?(id) ->
        refuse!(
          "error.msg.glaccount.glcode.invalid.delete.transactions.logged",
          "This GL Account cannot be deleted as it has transactions logged against it",
          id
        )

      GLAccounts.mapped_to_product?(id) ->
        refuse!(
          "error.msg.glaccount.glcode.invalid.delete.product.mapping",
          "Cannot delete this GL Account as it is mapped to a Product",
          id
        )

      true ->
        TenantRepo.delete_all(from(gl in "acc_gl_account", where: gl.id == ^id))
        Result.new(resource_id: id)
    end
  end

  # --- internals ------------------------------------------------------------------------------

  defp validate_for_update!(params) do
    name = Params.string(params, "name")
    gl_code = Params.string(params, "glCode")
    parent_id = Params.long(params, "parentId")
    type = Params.integer(params, "type")
    usage = Params.integer(params, "usage")
    description = Params.string(params, "description")
    disabled = Params.boolean(params, "disabled")

    validation =
      Validation.new("GLAccount")
      |> Validation.param("name", name)
      |> Validation.ignore_if_null()
      |> Validation.not_blank()
      |> Validation.max_length(200)
      |> Validation.param("glCode", gl_code)
      |> Validation.ignore_if_null()
      |> Validation.not_blank()
      |> Validation.max_length(45)
      |> Validation.param("parentId", parent_id)
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()
      |> Validation.param("type", type)
      |> Validation.ignore_if_null()
      |> Validation.in_range(1, 5)
      |> Validation.param("usage", usage)
      |> Validation.ignore_if_null()
      |> Validation.in_range(1, 2)
      |> Validation.param("description", description)
      |> Validation.ignore_if_null()
      |> Validation.max_length(500)

    # as in Fineract, only these count as "something to update" (not tagId, usage or manualEntriesAllowed)
    validation =
      if Enum.all?([name, gl_code, parent_id, type, description, disabled], &is_nil/1),
        do: Validation.no_parameters_for_update(validation),
        else: validation

    Validation.raise_if_errors!(validation)
  end

  # What really changes: the request's values against the account. A parent counts as changed whenever
  # one is given (Fineract compares it with zero); a missing tag never changes anything.
  defp changes(params, account) do
    %{}
    |> put_if(params, "description", account.description, &Params.string/2)
    |> put_if(params, "disabled", account.disabled, &Params.boolean/2)
    |> put_if(params, "glCode", account.gl_code, &Params.string/2)
    |> put_if(params, "manualEntriesAllowed", account.manual_entries_allowed, &Params.boolean/2)
    |> put_if(params, "name", account.name, &Params.string/2)
    |> parent_change(params)
    |> put_if(params, "type", account.type_id, &Params.integer/2)
    |> put_if(params, "usage", account.usage_id, &Params.integer/2)
    |> tag_id_change(params, account)
  end

  defp put_if(changes, params, key, existing, reader) do
    if Params.exists?(params, key) do
      new = reader.(params, key)
      if new != existing and new != nil, do: Map.put(changes, key, new), else: changes
    else
      changes
    end
  end

  defp parent_change(changes, params) do
    case Params.long(params, "parentId") do
      nil -> changes
      0 -> changes
      id -> Map.put(changes, "parentId", id)
    end
  end

  defp tag_id_change(changes, params, account) do
    current = account.tag && account.tag.id

    case Params.long(params, "tagId") do
      nil -> changes
      ^current -> changes
      id -> Map.put(changes, "tagId", id)
    end
  end

  # The column each change touches, with the value to store.
  defp stored(changes, parent, tag) do
    [
      {"description", :description, changes["description"]},
      {"disabled", :disabled, changes["disabled"]},
      {"glCode", :gl_code, changes["glCode"] && String.trim(changes["glCode"])},
      {"manualEntriesAllowed", :manual_journal_entries_allowed, changes["manualEntriesAllowed"]},
      {"name", :name, changes["name"] && String.trim(changes["name"])},
      {"parentId", :parent_id, parent && parent.id},
      {"type", :classification_enum, changes["type"]},
      {"usage", :account_usage, changes["usage"]},
      {"tagId", :tag_id, tag}
    ]
  end

  defp tag_change!(changes, params, account) do
    if Map.has_key?(changes, "tagId") do
      type = Map.get(changes, "type", account.type_id)
      tag!(Params.long(params, "tagId"), type)
    end
  end

  defp usage_to_header!(changes, account) do
    if changes["usage"] == 2 and GLAccounts.posted?(account.id),
      do:
        refuse!(
          "error.msg.glaccount.glcode.invalid.update.transactions.logged",
          "This (detail) GL Account cannot be updated as it already has transactions logged against it",
          account.id
        )
  end

  defp valid_parent!(parent_id) do
    parent = GLAccounts.fetch!(parent_id)

    if parent.usage_id == 1,
      do:
        raise(DomainRuleViolation,
          code: "error.msg.glaccount.parent.invalid",
          message:
            "The account with id #{parent_id} is a 'Detail' account and cannot be used as a parent",
          args: [parent_id]
        )

    parent
  end

  # The tag has to be a value of the code list for the account's type.
  defp tag!(tag_id, type) do
    name = GLAccounts.tag_code_name(type)

    found =
      name &&
        TenantRepo.one(
          from cv in "m_code_value",
            join: c in "m_code",
            on: c.id == cv.code_id,
            where: cv.id == ^tag_id and c.code_name == ^name,
            select: cv.id
        )

    found ||
      raise ResourceNotFound,
        code: "error.msg.codevalue.codename.id.combination.invalid",
        message:
          "Code value with identifier #{tag_id} does not exist for a code with name #{name}",
        args: [tag_id, name]
  end

  defp set_hierarchy!(id, parent) do
    path = if parent, do: GLAccounts.hierarchy(parent.id) <> "#{id}.", else: "."

    TenantRepo.update_all(from(gl in "acc_gl_account", where: gl.id == ^id),
      set: [hierarchy: path]
    )
  end

  # The account has a new parent: its path changes and so does the path of everything beneath it.
  defp move!(account, parent) do
    old = GLAccounts.hierarchy(account.id)
    new = GLAccounts.hierarchy(parent.id) <> "#{account.id}."

    TenantRepo.update_all(from(gl in "acc_gl_account", where: gl.id == ^account.id),
      set: [hierarchy: new]
    )

    TenantRepo.query!(
      "UPDATE acc_gl_account SET hierarchy = $1 || substr(hierarchy, $2) WHERE hierarchy LIKE $3 AND id <> $4",
      [new, String.length(old) + 1, old <> "%", account.id]
    )
  end

  defp refuse!(code, message, id),
    do: raise(DomainRuleViolation, code: code, message: message, args: [id])

  defp guard(gl_code, fun) do
    Integrity.translate(
      fun,
      %{
        "acc_gl_account_gl_code_key" =>
          {"error.msg.glaccount.glcode.duplicate",
           "General Ledger Account with GL code #{gl_code} is already present", nil, [gl_code]}
      },
      {"error.msg.glAccount.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource GL Account."}
    )
  end
end
