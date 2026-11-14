defmodule ECBPlatform.Commands do
  @moduledoc """
  The command pipeline: how every state-changing request is carried out.

  This follows Fineract's `PortfolioCommandSourceWritePlatformServiceImpl`,
  `SynchronousCommandProcessingService` and `CommandSourceService`, so the stored commands, statuses,
  maker-checker behaviour and idempotency rules are the same.

  ## What happens to a command

   1. **Who may do it.** The user needs the permission `<ACTION>_<ENTITY>`. A user who only holds the
      matching `_CHECKER` permission (or `CHECKER_SUPER_USER`) may not start the command but may approve
      an identical pending one.
   2. **Is it a duplicate?** Under maker-checker an identical command already waiting is refused. For
      every command, the idempotency key (the caller's, or a generated one) is looked up together
      with the action and entity: a request still running gives a 409 error, one that already
      succeeded or failed gives back the stored outcome.
   3. **It is recorded first.** A row in `m_portfolio_command_source` with status *under processing* is
      saved and committed on its own, so there is a trace even if everything after it fails, and a
      second identical request is seen immediately.
   4. **The handler runs in a transaction.** If maker-checker applies and the user is not a checker,
      the work is validated by running it and then undone, and the command waits as *awaiting approval*
      (the caller gets `RollbackNotApproved`, which an API answers with HTTP 202). Otherwise the result,
      the checker and the status *processed* are stored in the same transaction as the handler's changes.
   5. **A failure is recorded.** The transaction rolls back and the row is updated to *error* with the
      error and its HTTP status, in a transaction of its own.

  Every function returns `{:ok, result}` or `{:error, exception}` and must run inside
  `ECBPlatform.Tenancy.with_tenant/2`.
  """
  import Ecto.Query

  require Logger

  alias ECBPlatform.Commands.{
    Command,
    CommandSource,
    Errors,
    Handlers,
    Hrefs,
    Result,
    ResultType,
    Sanitizer
  }

  alias ECBPlatform.Configuration
  alias ECBPlatform.Security
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @type outcome :: {:ok, Result.t()} | {:error, Exception.t()}

  # --- starting a command ---------------------------------------------------------------------

  @doc """
  Runs a command as `user`.

  ## Options

    * `:retry` - set when the caller is retrying a command that previously failed, so the stored
      failure does not block it (default false)
  """
  @spec execute(Command.t(), User.t(), keyword) :: outcome()
  def execute(%Command{} = command, %User{} = user, opts \\ []) do
    rescue_known(fn -> start(command, user, Command.task_permission(command), opts) end)
  end

  defp start(command, user, task, opts) do
    if checker_only?(user, task),
      do: approve_pending(command, user, task),
      else: start_as_maker(command, user, task, opts)
  end

  # A checker who repeats a pending command approves it; with nothing pending they cannot start one.
  defp approve_pending(command, user, task) do
    case find_pending(command) do
      nil -> {:error, %Errors.CheckerOnlyInitiation{permission: task}}
      pending -> approve(pending.id, user)
    end
  end

  defp start_as_maker(command, user, task, opts) do
    with :ok <- Security.validate_has_permission(user, task),
         :ok <- check_no_duplicate_pending(command, user, task) do
      run(command, user, false, opts)
    end
  end

  # --- maker-checker actions ------------------------------------------------------------------

  @doc "Approves a command that is awaiting approval, running it as the checker."
  @spec approve(integer, User.t()) :: outcome()
  def approve(command_source_id, %User{} = user) do
    rescue_known(fn ->
      with {:ok, source} <- validate_maker_checker_transaction(command_source_id, user),
           :ok <- check_not_sanitized(source) do
        run(command_from_source(source), user, true, [])
      end
    end)
  end

  # A command whose secrets were masked cannot be run again from its stored copy.
  defp check_not_sanitized(%CommandSource{is_sanitized: true} = source) do
    {:error,
     %Errors.UnsupportedCommand{
       command: "#{source.action_name}_#{source.entity_name}",
       detail: "its stored copy holds no secrets, so it cannot be approved later"
     }}
  end

  defp check_not_sanitized(_source), do: :ok

  @doc "Rejects a command that is awaiting approval. Returns the command id."
  @spec reject(integer, User.t()) :: {:ok, integer} | {:error, Exception.t()}
  def reject(command_source_id, %User{} = user) do
    rescue_known(fn ->
      with {:ok, source} <- validate_maker_checker_transaction(command_source_id, user) do
        now = checked_at()

        source
        |> Ecto.Changeset.change(
          Map.merge(now, %{checker_id: user.id, status: ResultType.to_int(:rejected)})
        )
        |> TenantRepo.update!()

        {:ok, command_source_id}
      end
    end)
  end

  @doc "Deletes a command that is awaiting approval. Returns the command id."
  @spec delete(integer, User.t()) :: {:ok, integer} | {:error, Exception.t()}
  def delete(command_source_id, %User{} = user) do
    rescue_known(fn ->
      with {:ok, source} <- validate_maker_checker_transaction(command_source_id, user) do
        TenantRepo.delete!(source)
        {:ok, command_source_id}
      end
    end)
  end

  @doc "A stored command by id, or `nil`."
  @spec get(integer) :: CommandSource.t() | nil
  def get(command_source_id), do: TenantRepo.get(CommandSource, command_source_id)

  # --- permission and duplicate checks --------------------------------------------------------

  # A checker-only user cannot start the command, but may approve a pending one.
  defp checker_only?(user, task) do
    User.has_not_permission_for_any_of?(user, [task]) and
      not User.has_not_permission_for_any_of?(user, [
        "CHECKER_SUPER_USER",
        User.checker_permission(task)
      ])
  end

  defp check_no_duplicate_pending(command, user, task) do
    if Configuration.maker_checker_enabled_for_task?(task) and not User.checker_super_user?(user) and
         find_pending(command) != nil do
      {:error,
       %Errors.DuplicatePendingSubmission{
         action_name: command.action_name,
         entity_name: command.entity_name
       }}
    else
      :ok
    end
  end

  # An identical command (same body, same target) already waiting for approval.
  defp find_pending(%Command{entity_id: nil}), do: nil

  defp find_pending(%Command{} = command) do
    query =
      from c in CommandSource,
        where:
          c.action_name == ^command.action_name and c.entity_name == ^command.entity_name and
            c.resource_id == ^command.entity_id and
            c.command_as_json == ^Command.stored_json(command) and
            c.status == ^ResultType.to_int(:awaiting_approval),
        order_by: [desc: c.id],
        limit: 1

    query =
      if command.subentity_id,
        do: where(query, [c], c.subresource_id == ^command.subentity_id),
        else: where(query, [c], is_nil(c.subresource_id))

    TenantRepo.one(query)
  end

  defp validate_maker_checker_transaction(id, user) do
    with {:ok, source} <- fetch_source(id),
         :ok <- require_awaiting(source),
         :ok <-
           Security.validate_has_checker_permission(user, CommandSource.permission_code(source)) do
      check_not_same_user(source, user)
    end
  end

  defp fetch_source(id) do
    case TenantRepo.get(CommandSource, id) do
      nil -> {:error, %Errors.CommandNotFound{command_id: id}}
      source -> {:ok, source}
    end
  end

  defp require_awaiting(source) do
    if CommandSource.result_type(source) == :awaiting_approval,
      do: :ok,
      else: {:error, %Errors.CommandNotAwaitingApproval{command_id: source.id}}
  end

  # The maker may not check their own command unless the tenant allows it or the user is a super checker.
  defp check_not_same_user(source, user) do
    cond do
      Configuration.same_maker_checker_enabled?() or User.checker_super_user?(user) ->
        {:ok, source}

      is_nil(source.maker_id) ->
        {:error,
         %Errors.UnsupportedCommand{
           command: CommandSource.permission_code(source),
           detail: "Maker user is missing."
         }}

      source.maker_id == user.id ->
        {:error,
         %Errors.UnsupportedCommand{
           command: CommandSource.permission_code(source),
           detail: "Can not be checked by the same user."
         }}

      true ->
        {:ok, source}
    end
  end

  defp command_from_source(%CommandSource{} = s) do
    Command.new(s.action_name, s.entity_name,
      entity_id: s.resource_id,
      subentity_id: s.subresource_id,
      href: s.api_get_url,
      json: s.command_as_json,
      office_id: s.office_id,
      group_id: s.group_id,
      client_id: s.client_id,
      loan_id: s.loan_id,
      savings_id: s.savings_account_id,
      product_id: s.product_id,
      transaction_id: s.transaction_id,
      credit_bureau_id: s.creditbureau_id,
      organisation_credit_bureau_id: s.organisation_creditbureau_id,
      job_name: s.job_name,
      loan_external_id: s.loan_external_id,
      idempotency_key: s.idempotency_key,
      command_source_id: s.id
    )
  end

  # --- running --------------------------------------------------------------------------------

  defp run(command, user, approved_by_checker?, opts) do
    with {:ok, source} <- prepare_source(command, user, Keyword.get(opts, :retry, false)) do
      execute_source(command, user, approved_by_checker?, source)
    end
  end

  # Finds or creates the stored command, refusing a repeat of something already done or in flight.
  defp prepare_source(command, user, retry?) do
    with {:ok, existing, key} <- existing_source(command, retry?),
         :ok <- reject_if_already_processed(command, key, retry?) do
      if existing, do: {:ok, existing}, else: save_initial(command, user, key)
    end
  end

  # A retry carries on with the stored command of the earlier attempt, as Fineract's retry does,
  # rather than starting a second one under the same key.
  defp existing_source(%Command{command_source_id: nil} = command, retry?) do
    key = command.idempotency_key || Ecto.UUID.generate()
    {:ok, if(retry?, do: find_by_key(command, key)), key}
  end

  defp existing_source(%Command{command_source_id: id}, _retry?) do
    with {:ok, source} <- fetch_source(id), do: {:ok, source, source.idempotency_key}
  end

  defp reject_if_already_processed(command, key, retry?) do
    found = find_by_key(command, key)

    fields = [
      action_name: command.action_name,
      entity_name: command.entity_name,
      idempotency_key: key
    ]

    case found && CommandSource.result_type(found) do
      :under_processing ->
        {:error, struct(Errors.IdempotentUnderProcessing, fields)}

      :processed ->
        {:error, struct(Errors.IdempotentSucceeded, [command_source: found] ++ fields)}

      :error when not retry? ->
        {:error, struct(Errors.IdempotentFailed, [command_source: found] ++ fields)}

      _ ->
        :ok
    end
  end

  defp find_by_key(command, key) do
    TenantRepo.get_by(CommandSource,
      action_name: command.action_name,
      entity_name: command.entity_name,
      idempotency_key: key
    )
  end

  defp save_initial(command, user, key) do
    {stored_json, sanitized?} =
      Sanitizer.sanitize(command.entity_name, Command.stored_json(command))

    attrs = %{
      action_name: command.action_name,
      entity_name: command.entity_name,
      office_id: command.office_id,
      group_id: command.group_id,
      client_id: command.client_id,
      loan_id: command.loan_id,
      savings_account_id: command.savings_id,
      api_get_url:
        command.href ||
          Hrefs.resolve(
            command.entity_name,
            command.action_name,
            command.entity_id,
            command.subentity_id
          ),
      resource_id: command.entity_id,
      subresource_id: command.subentity_id,
      command_as_json: stored_json,
      maker_id: user.id,
      made_on_date: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second),
      made_on_date_utc: DateTime.utc_now(),
      status: ResultType.to_int(:under_processing),
      product_id: command.product_id,
      transaction_id: command.transaction_id,
      creditbureau_id: command.credit_bureau_id,
      organisation_creditbureau_id: command.organisation_credit_bureau_id,
      job_name: command.job_name,
      idempotency_key: key,
      resource_external_id: command.resource_external_id,
      subresource_external_id: command.subresource_external_id,
      loan_external_id: command.loan_external_id,
      is_sanitized: sanitized?,
      client_ip: command.client_ip
    }

    case %CommandSource{} |> CommandSource.initial_changeset(attrs) |> TenantRepo.insert() do
      {:ok, source} ->
        {:ok, source}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # A concurrent identical request won the unique (action, entity, key): this one is a duplicate in flight.
        if Keyword.has_key?(errors, :idempotency_key),
          do:
            {:error,
             %Errors.IdempotentUnderProcessing{
               action_name: command.action_name,
               entity_name: command.entity_name,
               idempotency_key: key
             }},
          else: raise(ArgumentError, "invalid command: #{inspect(changeset.errors)}")
    end
  end

  # The handler and the stored result share one transaction. Any failure rolls both back, then the
  # outcome is recorded in a transaction of its own.
  defp execute_source(command, user, approved_by_checker?, source) do
    outcome =
      try do
        TenantRepo.transaction(fn ->
          in_transaction(command, user, approved_by_checker?, source)
        end)
      rescue
        exception -> {:error, {exception, %{}}}
      end

    finish(outcome, command, source)
  end

  defp in_transaction(command, user, approved_by_checker?, source) do
    with {:ok, handler} <- Handlers.fetch(command.entity_name, command.action_name),
         {:ok, result} <- run_handler(handler, command, user),
         {:ok, checked} <- apply_maker_checker(source, user, approved_by_checker?, result),
         {:ok, saved} <- save_success(source, result, checked) do
      {result, saved}
    else
      {:error, exception} when is_exception(exception) -> TenantRepo.rollback({exception, %{}})
      {:error, exception, attrs} -> TenantRepo.rollback({exception, attrs})
    end
  end

  defp run_handler(handler, command, user) do
    case handler.process(command, user) do
      {:ok, %Result{} = result} ->
        {:ok, result}

      {:error, exception} when is_exception(exception) ->
        {:error, exception}

      other ->
        {:error, %RuntimeError{message: "handler #{inspect(handler)} returned #{inspect(other)}"}}
    end
  end

  # Under maker-checker (or a dry run) only a checker's approval lets the work stand.
  defp apply_maker_checker(source, user, approved_by_checker?, result) do
    if Configuration.maker_checker_enabled_for_task?(CommandSource.permission_code(source)) or
         result.rollback_transaction do
      if approved_by_checker? or User.checker_super_user?(user) do
        {:ok, Map.merge(checked_at(), %{checker_id: user.id})}
      else
        {:error,
         %Errors.RollbackNotApproved{command_id: source.id, resource_id: source.resource_id},
         %{status: ResultType.to_int(:awaiting_approval)}}
      end
    else
      {:ok, %{}}
    end
  end

  defp save_success(source, result, checked) do
    attrs =
      Map.merge(checked, %{
        result_status_code: 200,
        office_id: result.office_id,
        group_id: result.group_id,
        client_id: result.client_id,
        loan_id: result.loan_id,
        savings_account_id: result.savings_id,
        product_id: result.product_id,
        transaction_id: result.transaction_id,
        resource_id: result.resource_id,
        resource_external_id: external_id(result.resource_external_id),
        subresource_id: result.subresource_id,
        subresource_external_id: external_id(result.subresource_external_id),
        loan_external_id: external_id(result.loan_external_id),
        result: Result.to_json(result),
        status: ResultType.to_int(:processed)
      })

    source |> Ecto.Changeset.change(attrs) |> TenantRepo.update()
  end

  defp external_id(nil), do: nil
  defp external_id(value) when is_binary(value), do: value
  defp external_id(value), do: to_string(value)

  # --- recording the outcome ------------------------------------------------------------------

  defp finish({:ok, {result, saved}}, command, _source) do
    run_hooks(:after_success, [command, result])
    _ = saved
    {:ok, result}
  end

  defp finish({:error, {exception, attrs}}, command, source) when is_exception(exception) do
    record_failure(source, exception, attrs)
    run_hooks(:after_error, [command, exception])
    {:error, exception}
  end

  # An approval waits as "awaiting approval" with a 202; anything else becomes an error row.
  defp record_failure(source, %Errors.RollbackNotApproved{} = exception, attrs) do
    update_outcome(
      source,
      Map.merge(attrs, %{result_status_code: 200, result: error_json(exception)})
    )
  end

  defp record_failure(source, exception, _attrs) do
    status = Errors.http_status(exception)
    base = %{result_status_code: status, result: error_json(exception)}

    update_outcome(
      source,
      if(status == 200, do: base, else: Map.put(base, :status, ResultType.to_int(:error)))
    )
  end

  defp update_outcome(source, attrs) do
    source |> Ecto.Changeset.change(attrs) |> TenantRepo.update!()
  rescue
    # Never mask the original failure because recording it failed.
    exception ->
      Logger.error(
        "could not record the outcome of command #{source.id}: #{Exception.message(exception)}"
      )
  end

  defp error_json(exception), do: exception |> Errors.to_api_map() |> Jason.encode!()

  defp checked_at do
    %{
      checked_on_date: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second),
      checked_on_date_utc: DateTime.utc_now()
    }
  end

  # Hooks (webhooks, the event outbox) are told after the outcome is stored. A failing hook never
  # changes the result of the command.
  defp run_hooks(callback, args) do
    for module <- Application.get_env(:ecb_platform, :command_hooks, []) do
      try do
        apply(module, callback, args)
      rescue
        exception ->
          Logger.error(
            "command hook #{inspect(module)}.#{callback} failed: #{Exception.message(exception)}"
          )
      end
    end

    :ok
  end

  # Errors that are reported to the caller rather than crashing the request.
  defp rescue_known(fun) do
    fun.()
  rescue
    exception in [Errors.PermissionNotFound, Errors.UnsupportedCommand, Errors.CommandNotFound] ->
      {:error, exception}
  end
end
