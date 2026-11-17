defmodule ECBPlatform.Jobs do
  @moduledoc """
  The scheduler jobs (`job`, `job_run_history`): the list Fineract ships with, and the means to run one.

  A job is known by its short name (`ACC_APTR`...). The code behind it belongs to a domain app, which registers
  it when it starts (`register/2`): a module with `run(user)` returning `:ok`, run inside the tenant. A job
  with no code behind it is listed but cannot be run: running it is refused, never pretended.

  Jobs are run on request (`run/3`, `POST /jobs/:id?command=executeJob`) and, when the scheduler is switched on,
  by their cron expression (`ECBPlatform.Scheduler`). A job runs once at a time: a second request while it runs
  is not run.
  """
  import Ecto.Query
  require Logger

  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.TenantRepo

  @key {__MODULE__, :runners}

  @doc "Registers `module` as the code of the job `short_name`."
  @spec register(String.t(), module) :: :ok
  def register(short_name, module) when is_binary(short_name) and is_atom(module),
    do: :persistent_term.put(@key, Map.put(runners(), short_name, module))

  @doc "Whether there is code behind the job."
  @spec runnable?(String.t()) :: boolean
  def runnable?(short_name), do: Map.has_key?(runners(), short_name)

  @doc "All jobs, with their last run."
  @spec list() :: [map]
  def list, do: TenantRepo.all(base()) |> Enum.map(&with_last_run/1)

  @doc """
  One job by id or short name, or `{:error, ResourceNotFound}`. Fineract words the error differently for a job
  that is read (`:read`) and for one that is to be run (`:run`).
  """
  @spec get(integer | String.t(), :read | :run) :: {:ok, map} | {:error, Exception.t()}
  def get(identifier, purpose \\ :read)

  def get(id, purpose) when is_integer(id),
    do: fetch(from(j in base(), where: j.id == ^id), id, purpose)

  def get(short_name, purpose) when is_binary(short_name),
    do: fetch(from(j in base(), where: j.short_name == ^short_name), short_name, purpose)

  defp fetch(query, identifier, purpose) do
    case TenantRepo.one(query) do
      nil -> {:error, not_found(identifier, purpose)}
      job -> {:ok, with_last_run(job)}
    end
  end

  defp not_found(identifier, :run) do
    %ResourceNotFound{
      code: "error.msg.sheduler.job.id.invalid",
      message: "Job with identifier #{identifier} does not exist",
      args: [to_string(identifier)]
    }
  end

  defp not_found(identifier, :read) do
    %ResourceNotFound{
      code: "error.msg.sheduler.job.id.invalid",
      message: "Job with ID: #{identifier} cannot be found",
      args: ["ID", to_string(identifier)]
    }
  end

  defp base do
    from(j in "job",
      order_by: j.id,
      select: %{
        id: j.id,
        display_name: j.display_name,
        short_name: j.short_name,
        cron_expression: j.cron_expression,
        active: j.is_active,
        currently_running: j.currently_running
      }
    )
  end

  defp with_last_run(job), do: Map.put(job, :last_run, last_run(job.id))

  defp last_run(job_id) do
    TenantRepo.one(
      from(h in "job_run_history",
        where: h.job_id == ^job_id,
        order_by: [desc: h.version],
        limit: 1,
        select: %{
          id: h.id,
          version: h.version,
          start_time: h.start_time,
          end_time: h.end_time,
          status: h.status,
          trigger_type: h.trigger_type,
          error_message: h.error_message,
          error_log: h.error_log
        }
      )
    )
  end

  @doc "The runs of a job, newest first."
  @spec history(integer) :: [map]
  def history(job_id) do
    TenantRepo.all(
      from(h in "job_run_history",
        where: h.job_id == ^job_id,
        order_by: [desc: h.version],
        select: %{
          id: h.id,
          version: h.version,
          start_time: h.start_time,
          end_time: h.end_time,
          status: h.status,
          trigger_type: h.trigger_type,
          error_message: h.error_message,
          error_log: h.error_log
        }
      )
    )
  end

  @doc """
  Runs the job `id`, as the user `system`, and records the run. Returns `:ok`, or `:failed` when the job raised:
  as in Fineract, whose jobs run after the request is answered, a failure is recorded in the job's history and
  logged, not returned to whoever asked.
  """
  @spec run(integer, struct | nil, String.t()) :: :ok | :failed | :busy
  def run(id, user, trigger \\ "application") do
    {:ok, job} = get(id)

    case Map.fetch(runners(), job.short_name) do
      {:ok, module} ->
        started = NaiveDateTime.utc_now()

        if claim(job.id, started) do
          try do
            module.run(system_user(user))
            record!(job.id, started, "success", nil, nil, trigger)
          rescue
            error ->
              message = Exception.message(error)

              record!(
                job.id,
                started,
                "failed",
                message,
                Exception.format(:error, error, __STACKTRACE__),
                trigger
              )

              Logger.error("The job #{job.short_name} failed: #{message}")
              :failed
          after
            release(job.id)
          end
        else
          Logger.warning("The job #{job.short_name} is running already")
          :busy
        end

      :error ->
        raise DomainRuleViolation,
          code: "error.msg.scheduler.job.not.supported.yet",
          message:
            "The job #{job.display_name} (#{job.short_name}) is not supported yet by E-CoreBank",
          args: [job.short_name]
    end
  end

  # a job works as the user `system`, whoever asked for it to be run
  defp system_user(requested_by) do
    case TenantRepo.one(from(u in "m_appuser", where: u.username == "system", select: u.id)) do
      nil -> requested_by
      id -> %{id: id, username: "system"}
    end
  end

  # A job runs once at a time: whoever sets `currently_running` first has it. A flag left from a run that never
  # ended (the node went down) is given up after an hour.
  defp claim(job_id, started) do
    {count, _} =
      TenantRepo.update_all(
        from(j in "job",
          where:
            j.id == ^job_id and
              (not j.currently_running or
                 j.previous_run_start_time < ^NaiveDateTime.add(started, -3600))
        ),
        set: [currently_running: true, previous_run_start_time: started]
      )

    count == 1
  end

  defp release(job_id),
    do:
      TenantRepo.update_all(from(j in "job", where: j.id == ^job_id),
        set: [currently_running: false]
      )

  defp record!(job_id, started, status, message, log, trigger) do
    version =
      (TenantRepo.one(
         from(h in "job_run_history", where: h.job_id == ^job_id, select: max(h.version))
       ) || 0) + 1

    TenantRepo.insert_all("job_run_history", [
      %{
        job_id: job_id,
        version: version,
        start_time: started,
        end_time: NaiveDateTime.utc_now(),
        status: status,
        trigger_type: trigger,
        error_message: message,
        error_log: log
      }
    ])

    TenantRepo.update_all(from(j in "job", where: j.id == ^job_id),
      set: [previous_run_start_time: started]
    )

    :ok
  end

  defp runners, do: :persistent_term.get(@key, %{})
end
