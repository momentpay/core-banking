defmodule ECBLoans.Notes do
  @moduledoc """
  The notes people write against a client, a loan or a loan transaction (`m_note`), following Fineract's
  `NotesApiResource` and its read and write services.

  A note belongs to a *resource type* named in the URL: `clients`, `loans` or `loanTransactions`. What each lists:
  a client its client notes, a loan its own notes and those of its transactions, a loan transaction the notes made
  on it. Fineract finds a note to change or delete by the resource's own id alone, whatever the kind of the note,
  so a loan's note can be changed through its client's URL; that is kept.

  Notes of groups, savings accounts and shares are not here yet.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBParty.Clients
  alias ECBPlatform.{Errors, TenantRepo, Validation}

  @client 100
  @loan 200
  @loan_transaction 300

  @kinds %{"clients" => :client, "loans" => :loan, "loanTransactions" => :loan_transaction}
  @not_built ~w(groups savings savingsTransactions accounts/share)

  @doc "The kind of resource a URL names, or raises the error Fineract answers with (or one saying it is not built)."
  @spec kind!(String.t()) :: :client | :loan | :loan_transaction
  def kind!(resource_type) do
    cond do
      kind = @kinds[resource_type] ->
        kind

      resource_type in @not_built ->
        raise Errors.DomainRuleViolation,
          code: "error.msg.note.feature.not.supported.yet",
          message: "Notes of #{resource_type} are not supported yet by E-CoreBank",
          args: [resource_type]

      true ->
        raise Errors.ResourceNotFound,
          code: "error.msg.note.resource.not.supported",
          message: "Note does not support resource #{resource_type}",
          args: []
    end
  end

  # --- reads ------------------------------------------------------------------------------------

  @doc "The notes of a resource; a resource that does not exist has none."
  @spec list(atom, integer) :: [map]
  def list(kind, resource_id) do
    {condition, params} = resource_condition(kind, resource_id)
    query("WHERE #{condition}", params)
  end

  @doc "One note of a resource, or raises not found."
  @spec get!(atom, integer, integer) :: map
  def get!(kind, resource_id, note_id) do
    {condition, params} = resource_condition(kind, resource_id)

    case query("WHERE n.id = $#{length(params) + 1} AND #{condition}", params ++ [note_id]) do
      [note] -> note
      [] -> raise not_found(kind, note_id, resource_id)
    end
  end

  # what each resource type lists (the ids come first among the parameters)
  defp resource_condition(:client, id),
    do: {"n.client_id = $1 AND n.note_type_enum = #{@client}", [id]}

  defp resource_condition(:loan, id),
    do:
      {"n.loan_id = $1 AND (n.note_type_enum = #{@loan} OR n.note_type_enum = #{@loan_transaction})",
       [id]}

  defp resource_condition(:loan_transaction, id), do: {"n.loan_transaction_id = $1", [id]}

  # Fineract has no order for them (its sort column is never filled in): rows come as the database holds them,
  # and a row that is changed goes to the end
  defp query(where, params) do
    TenantRepo.query!(
      """
      SELECT n.id, n.client_id, n.loan_id, n.loan_transaction_id, n.note_type_enum, n.note,
             n.created_by, cu.username AS created_by_username, n.created_on_utc,
             n.last_modified_by, mu.username AS modified_by_username, n.last_modified_on_utc
      FROM m_note n
      LEFT JOIN m_appuser cu ON cu.id = n.created_by
      LEFT JOIN m_appuser mu ON mu.id = n.last_modified_by
      #{where}
      ORDER BY GREATEST(n.created_on_utc, n.last_modified_on_utc), n.id
      """,
      params
    )
    |> rows()
  end

  # --- writes -----------------------------------------------------------------------------------

  @doc "Adds a note; returns `{note id, office id}`."
  @spec create!(atom, integer, term, struct) :: {integer, integer}
  def create!(kind, resource_id, text, user) do
    text = text!(text, "addNewNote.request.note")
    {client_id, loan_id, transaction_id, type, office_id} = owner!(kind, resource_id)
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_note",
        [
          %{
            client_id: client_id,
            loan_id: loan_id,
            loan_transaction_id: transaction_id,
            note_type_enum: type,
            note: text,
            created_by: user.id,
            created_on_utc: now,
            last_modified_by: user.id,
            last_modified_on_utc: now
          }
        ],
        returning: [:id]
      )

    {id, office_id}
  end

  # who the note belongs to; the resource must exist
  defp owner!(:client, id) do
    client = Clients.fetch!(id)
    {id, nil, nil, @client, client.office_id}
  end

  defp owner!(:loan, id) do
    loan = Loans.fetch!(id)
    {loan.client_id, id, nil, @loan, loan.client_office_id}
  end

  defp owner!(:loan_transaction, id) do
    tx =
      TenantRepo.one(
        from(t in "m_loan_transaction", where: t.id == ^id, select: %{loan_id: t.loan_id})
      )

    if tx == nil, do: raise(Loans.transaction_not_found(id))
    loan = Loans.fetch!(tx.loan_id)
    {loan.client_id, loan.id, id, @loan_transaction, loan.client_office_id}
  end

  @doc """
  Changes a note's text. Returns `{office id, changes}`: `changes` is empty when the new text is the same, whatever
  its case.
  """
  @spec update!(atom, integer, integer, term, struct) :: {integer, map}
  def update!(kind, resource_id, note_id, text, user) do
    text = text!(text, "updateNote.request.note")
    {note, office_id} = lookup!(kind, resource_id, note_id)

    if String.downcase(note.note || "") == String.downcase(text) do
      {office_id, %{}}
    else
      TenantRepo.update_all(from(n in "m_note", where: n.id == ^note_id),
        set: [note: text, last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]
      )

      {office_id, %{"note" => text}}
    end
  end

  @doc "Deletes a note."
  @spec delete!(atom, integer, integer) :: integer
  def delete!(kind, resource_id, note_id) do
    lookup!(kind, resource_id, note_id)
    TenantRepo.delete_all(from(n in "m_note", where: n.id == ^note_id))
    note_id
  end

  # A note is found by its owner's id alone, of any kind (as Fineract's repository does), after the owner is known
  defp lookup!(kind, resource_id, note_id) do
    {_client, _loan, _tx, _type, office_id} = owner!(kind, resource_id)

    column =
      case kind do
        :client -> "n.client_id"
        :loan -> "n.loan_id"
        :loan_transaction -> "n.loan_transaction_id"
      end

    case query("WHERE n.id = $2 AND #{column} = $1", [resource_id, note_id]) do
      [note] -> {note, office_id}
      [] -> raise not_found(kind, note_id, resource_id)
    end
  end

  defp text!(nil, param), do: missing!(param)
  defp text!(text, _param) when is_binary(text), do: text
  defp text!(other, _param), do: to_string(other)

  defp missing!(param) do
    Validation.new("note")
    |> Validation.add_error(
      "org.apache.fineract.portfolio.note.note.not-null",
      "The parameter 'note' cannot be empty",
      param,
      []
    )
    |> Validation.raise_if_errors!()
  end

  defp not_found(kind, note_id, resource_id) do
    word = kind |> Atom.to_string()

    Errors.ResourceNotFound.new(
      "error.msg.#{word}.note.id.invalid",
      "Note with identifier #{note_id} does not exist for #{word} with identifier #{resource_id}",
      [note_id, resource_id]
    )
  end

  defp rows(%{columns: columns, rows: rows}) do
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
  end
end
