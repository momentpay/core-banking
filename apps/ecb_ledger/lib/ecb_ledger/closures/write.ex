defmodule ECBLedger.Closures.Write do
  @moduledoc """
  Creating, changing and deleting accounting closures, following Fineract's
  `GLClosureWritePlatformServiceJpaRepositoryImpl`.

  A closure cannot be dated in the future or before the office's latest closure, and an office has one
  closure per date. Only the comments can be changed afterwards. Only the latest closure of an office can
  be deleted. Runs inside a command's transaction.
  """
  import Ecto.Query

  alias ECBLedger.Closures
  alias ECBOrg.Offices
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.{Params, TenantRepo, Validation}

  @unique "office_id_closing_date"

  @doc "Closes the books of an office up to a date."
  @spec create!(Params.t(), map) :: Result.t()
  def create!(%Params{} = params, user) do
    date = Params.date(params, "closingDate")
    office_id = Params.long(params, "officeId")
    comments = Params.string(params, "comments")

    Validation.new("GLClosure")
    |> Validation.param("closingDate", date)
    |> Validation.not_blank()
    |> Validation.param("officeId", office_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("comments", comments)
    |> Validation.ignore_if_null()
    |> Validation.max_length(500)
    |> Validation.raise_if_errors!()

    {:ok, _office} = fetch_office!(office_id)

    if Date.compare(date, BusinessDate.current()) == :gt,
      do:
        refuse(
          "error.msg.glclosure.invalid.future.date",
          "Accounting closures cannot be made for a future date",
          [Date.to_iso8601(date)]
        )

    latest = Closures.latest_date(office_id)

    if latest && Date.compare(latest, date) == :gt,
      do:
        refuse(
          "error.msg.glclosure.invalid.accounting.closed",
          "Accounting Closure for this branch has already been defined for a greater date",
          [Date.to_iso8601(latest)]
        )

    now = now()

    {1, [%{id: id}]} =
      guard(office_id, date, fn ->
        TenantRepo.insert_all(
          "acc_gl_closure",
          [
            %{
              office_id: office_id,
              closing_date: date,
              is_deleted: false,
              comments: comments && String.trim(comments),
              createdby_id: user.id,
              lastmodifiedby_id: user.id,
              created_date: now,
              lastmodified_date: now
            }
          ],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id, office_id: office_id)
  end

  @doc "Changes the comments of closure `id`."
  @spec update!(integer, Params.t(), map) :: Result.t()
  def update!(id, %Params{} = params, user) do
    comments = Params.string(params, "comments")

    validation =
      Validation.new("GLClosure")
      |> Validation.param("comments", comments)
      |> Validation.ignore_if_null()
      |> Validation.max_length(500)

    validation =
      if is_nil(comments), do: Validation.no_parameters_for_update(validation), else: validation

    Validation.raise_if_errors!(validation)

    closure = Closures.fetch!(id)

    changes =
      if comments != closure.comments, do: %{"comments" => comments}, else: %{}

    unless changes == %{} do
      now = now()

      TenantRepo.update_all(from(c in "acc_gl_closure", where: c.id == ^id),
        set: [comments: comments, lastmodifiedby_id: user.id, lastmodified_date: now]
      )
    end

    Result.new(
      resource_id: id,
      office_id: closure.office_id,
      changes: if(changes == %{}, do: nil, else: changes)
    )
  end

  @doc "Deletes closure `id`, which has to be the latest of its office."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    closure = Closures.fetch!(id)
    latest = Closures.latest_date(closure.office_id)

    if Date.compare(latest, closure.closing_date) == :gt,
      do:
        refuse(
          "error.msg.glclosure.invalid.delete",
          "The latest closure for office with Id #{closure.office_id} and name #{closure.office_name} " <>
            "is on #{Date.to_iso8601(latest)}, please delete this closure first",
          [Date.to_iso8601(latest)]
        )

    TenantRepo.delete_all(from(c in "acc_gl_closure", where: c.id == ^id))
    Result.new(resource_id: id, office_id: closure.office_id)
  end

  # --- internals ------------------------------------------------------------------------------

  defp fetch_office!(office_id) do
    case Offices.get(office_id) do
      {:ok, office} -> {:ok, office}
      {:error, error} -> raise error
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp refuse(code, message, args),
    do: raise(DomainRuleViolation, code: code, message: message, args: args)

  defp guard(office_id, date, fun) do
    fun.()
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :unique_violation, constraint: @unique} ->
          refuse(
            "error.msg.glclosure.glcode.duplicate",
            "An accounting closure for branch with Id #{office_id} already exists for the date #{Date.to_iso8601(date)}",
            [office_id, Date.to_iso8601(date)]
          )

        _ ->
          reraise error, __STACKTRACE__
      end
  end
end
