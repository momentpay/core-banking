defmodule ECBApiFineract.Resources.Notes do
  @moduledoc """
  `/v1/{resourceType}/{id}/notes`: the notes of a client, a loan or a loan transaction (`ECBLoans.Notes`), as
  Fineract's `NotesApiResource` answers them.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.Write
  alias ECBLoans.Notes

  @doc "`GET /{resourceType}/{id}/notes`"
  def index(conn, type, raw_id) do
    run(conn, raw_id, fn id ->
      kind = Notes.kind!(type)
      Response.json(conn, 200, kind |> Notes.list(id) |> Enum.map(&note_json/1))
    end)
  end

  @doc "`GET /{resourceType}/{id}/notes/{noteId}`"
  def show(conn, type, raw_id, raw_note_id) do
    run(conn, raw_id, raw_note_id, fn id, note_id ->
      kind = Notes.kind!(type)
      Response.json(conn, 200, note_json(Notes.get!(kind, id, note_id)))
    end)
  end

  @doc "`POST /{resourceType}/{id}/notes`"
  def create(conn, type, raw_id) do
    run(conn, raw_id, fn id ->
      kind = Notes.kind!(type)

      {note_id, office_id} =
        Notes.create!(kind, id, body(conn)["note"], conn.assigns.current_user)

      Response.json(conn, 200, %{
        "officeId" => office_id,
        "resourceId" => note_id,
        "entityId" => note_id
      })
    end)
  end

  @doc "`PUT /{resourceType}/{id}/notes/{noteId}`"
  def update(conn, type, raw_id, raw_note_id) do
    run(conn, raw_id, raw_note_id, fn id, note_id ->
      kind = Notes.kind!(type)

      {office_id, changes} =
        Notes.update!(kind, id, note_id, body(conn)["note"], conn.assigns.current_user)

      body = %{"officeId" => office_id, "resourceId" => id}

      Response.json(
        conn,
        200,
        if(changes == %{}, do: body, else: Map.put(body, "changes", changes))
      )
    end)
  end

  @doc "`DELETE /{resourceType}/{id}/notes/{noteId}`"
  def delete(conn, type, raw_id, raw_note_id) do
    run(conn, raw_id, raw_note_id, fn id, note_id ->
      kind = Notes.kind!(type)
      Response.json(conn, 200, %{"resourceId" => Notes.delete!(kind, id, note_id)})
    end)
  end

  defp run(conn, raw_id, fun) do
    Write.with_path_id(conn, raw_id, fn id -> guarded(conn, fn -> fun.(id) end) end)
  end

  defp run(conn, raw_id, raw_note_id, fun) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, note_id} <- Write.path_id(raw_note_id) do
      guarded(conn, fn -> fun.(id, note_id) end)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  # what the work raises about the request is answered as Fineract answers it
  defp guarded(conn, fun) do
    fun.()
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: Errors.render(conn, error),
        else: reraise(error, __STACKTRACE__)
  end

  defp body(conn) do
    case Jason.decode(conn.assigns[:raw_body] || "") do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp note_json(n) do
    %{
      "id" => n.id,
      "noteType" => note_type(n.note_type_enum),
      "note" => n.note,
      "createdById" => n.created_by,
      "createdByUsername" => n.created_by_username,
      "createdOn" => n.created_on_utc,
      "updatedById" => n.last_modified_by,
      "updatedByUsername" => n.modified_by_username,
      "updatedOn" => n.last_modified_on_utc
    }
    |> put("clientId", n.client_id)
    |> put("loanId", n.loan_id)
    |> put("loanTransactionId", n.loan_transaction_id)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp note_type(100), do: %{"id" => 100, "code" => "noteType.client", "value" => "Client note"}
  defp note_type(200), do: %{"id" => 200, "code" => "noteType.loan", "value" => "Loan note"}

  defp note_type(300),
    do: %{"id" => 300, "code" => "noteType.loan.transaction", "value" => "Loan transaction note"}
end
