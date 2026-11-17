defmodule ECBPlatform.Scheduler do
  @moduledoc """
  Starts the scheduler jobs by their cron expression (Fineract does it with Quartz).

  A process wakes up every `:interval` (30 seconds) and, for every tenant, runs the jobs that are due
  (`run_due/1`): active, with code behind them (`ECBPlatform.Jobs.register/2`), and with a `next_run_time` that
  has come. A job that is found without one is given the next time its cron expression fires, not run. After a
  job is started its `next_run_time` moves to the next firing, so a node that was down, or a run that took long,
  makes a job run once and not once per firing missed. Jobs due together run one after the other, those of
  higher priority first (a higher `task_priority` first, as in Quartz). A job is run by one node at a time (see
  `ECBPlatform.Jobs`), so several nodes can run the scheduler.

  The process is only started when the scheduler is switched on: `config :ecb_platform, ECBPlatform.Scheduler,
  enabled: true` (in releases, the environment variable `ECB_SCHEDULER=true`). Cron expressions are read as UTC.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias ECBPlatform.{Cron, Jobs, Tenancy, TenantRepo}

  @interval 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the scheduler is switched on."
  @spec enabled?() :: boolean
  def enabled?, do: Application.get_env(:ecb_platform, __MODULE__, [])[:enabled] == true

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    send(self(), :tick)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, %{interval: interval} = state) do
    try do
      run_due()
    rescue
      error -> Logger.error("The scheduler failed: " <> Exception.message(error))
    end

    Process.send_after(self(), :tick, interval)
    {:noreply, state}
  end

  @doc """
  Runs, for every tenant, the jobs that are due at `now`. Returns the short names of the jobs that were started,
  as `{tenant identifier, short name}`.
  """
  @spec run_due(NaiveDateTime.t()) :: [{String.t(), String.t()}]
  def run_due(now \\ NaiveDateTime.utc_now()) do
    Enum.flat_map(Tenancy.list_tenants(), &run_due_in(&1, now))
  end

  defp run_due_in(tenant, now) do
    case Tenancy.with_tenant(tenant, fn -> run_tenant(now) end) do
      {:ok, started} ->
        Enum.map(started, &{tenant.identifier, &1})

      {:error, reason} ->
        Logger.error("The scheduler cannot reach tenant #{tenant.identifier}: #{inspect(reason)}")
        []
    end
  end

  defp run_tenant(now) do
    candidates =
      TenantRepo.all(
        from(j in "job",
          where: j.is_active,
          order_by: [desc: j.task_priority, asc: j.id],
          select: %{
            id: j.id,
            short_name: j.short_name,
            cron: j.cron_expression,
            next: j.next_run_time
          }
        )
      )
      |> Enum.filter(&Jobs.runnable?(&1.short_name))

    for job <- candidates, due?(job, now), reduce: [] do
      started ->
        case Jobs.run(job.id, nil, "cron") do
          :busy -> started
          _ -> [job.short_name | started]
        end
    end
    |> Enum.reverse()
  end

  # A job with no next time is given one. One whose time has come moves to the next firing, then runs.
  defp due?(%{next: nil} = job, now) do
    schedule!(job, now)
    false
  end

  defp due?(%{next: next} = job, now) do
    if NaiveDateTime.compare(next, now) != :gt do
      schedule!(job, now)
      true
    else
      false
    end
  end

  defp schedule!(job, now) do
    next =
      try do
        Cron.next(job.cron, now)
      rescue
        ArgumentError ->
          Logger.error("The job #{job.short_name} has a cron expression that cannot be read")
          nil
      end

    TenantRepo.update_all(from(j in "job", where: j.id == ^job.id), set: [next_run_time: next])
  end
end
