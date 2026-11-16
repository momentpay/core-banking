defmodule ECBApiFineract.Resources.Jobs do
  @moduledoc """
  `/v1/jobs`: the scheduler jobs, their run history, and running one on request.

  Reading needs the permission `READ_SCHEDULER`; running a job needs `EXECUTEJOB_SCHEDULER` (or
  `ALL_FUNCTIONS`). Fineract answers a run with 202 and does the work after; E-CoreBank does the work first and
  then answers 202, so the work is done when the answer comes. The next run time is not given, because jobs are
  not started by their cron expression yet (see `ECBPlatform.Jobs`).
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.Read
  alias ECBPlatform.Commands.Errors.NoAuthorization
  alias ECBPlatform.Errors.UnrecognizedQueryParameter
  alias ECBPlatform.Jobs
  alias ECBPlatform.Security.User

  @doc "`GET /jobs`"
  def index(conn), do: Read.respond(conn, "SCHEDULER", fn -> Enum.map(Jobs.list(), &job/1) end)

  @doc "`GET /jobs/:id` and `GET /jobs/short-name/:short_name`"
  def show(conn, identifier) do
    Read.respond(conn, "SCHEDULER", fn ->
      with {:ok, job} <- Jobs.get(identifier(identifier)), do: job(job)
    end)
  end

  @doc "`GET /jobs/:id/runhistory` and `GET /jobs/short-name/:short_name/runhistory`"
  def history(conn, identifier) do
    Read.respond(conn, "SCHEDULER", fn ->
      with {:ok, job} <- Jobs.get(identifier(identifier)) do
        runs = Jobs.history(job.id)
        %{"totalFilteredRecords" => length(runs), "pageItems" => Enum.map(runs, &run/1)}
      end
    end)
  end

  @doc "`POST /jobs/:id?command=executeJob` and `POST /jobs/short-name/:short_name?command=executeJob`"
  def execute(conn, identifier) do
    user = conn.assigns.current_user

    if User.has_permission?(user, "ALL_FUNCTIONS") or
         User.has_permission?(user, "EXECUTEJOB_SCHEDULER") do
      run_command(conn, identifier, user)
    else
      Errors.render(
        conn,
        NoAuthorization.exception(
          permission: "EXECUTEJOB_SCHEDULER",
          message: "User has no authority to execute scheduler jobs"
        )
      )
    end
  end

  defp run_command(conn, identifier, user) do
    command = conn.query_params["command"]

    if is_binary(command) and String.downcase(String.trim(command)) == "executejob" do
      with {:ok, job} <- Jobs.get(identifier(identifier), :run) do
        Jobs.run(job.id, user)
        Plug.Conn.send_resp(conn, 202, "")
      end
    else
      {:error, %UnrecognizedQueryParameter{name: "command", value: command || "", allowed: []}}
    end
    |> case do
      %Plug.Conn{} = conn -> conn
      {:error, error} -> Errors.render(conn, error)
    end
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: Errors.render(conn, error),
        else: reraise(error, __STACKTRACE__)
  end

  # a job is found by its id, or by its short name when the path says so
  defp identifier(identifier) do
    case Integer.parse(to_string(identifier)) do
      {id, ""} -> id
      _ -> identifier
    end
  end

  defp job(j) do
    %{
      "jobId" => j.id,
      "displayName" => j.display_name,
      "shortName" => j.short_name,
      "cronExpression" => j.cron_expression,
      "active" => j.active,
      "currentlyRunning" => j.currently_running
    }
    |> Map.merge(if j.last_run, do: %{"lastRunHistory" => last_run(j.last_run)}, else: %{})
  end

  defp last_run(r) do
    %{
      "version" => r.version,
      "jobRunStartTime" => time(r.start_time),
      "jobRunEndTime" => time(r.end_time),
      "status" => r.status,
      "triggerType" => r.trigger_type
    }
  end

  defp run(r) do
    last_run(r)
    |> Map.put("id", r.id)
    |> then(
      &if(r.error_message, do: Map.put(&1, "jobRunErrorMessage", r.error_message), else: &1)
    )
    |> then(&if(r.error_log, do: Map.put(&1, "jobRunErrorLog", r.error_log), else: &1))
  end

  # an instant as Java prints it: whole seconds, or three, six or nine fraction digits
  defp time(%NaiveDateTime{} = t) do
    {micro, _} = t.microsecond
    base = t |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

    cond do
      micro == 0 -> base <> "Z"
      rem(micro, 1000) == 0 -> base <> "." <> pad(div(micro, 1000), 3) <> "Z"
      true -> base <> "." <> pad(micro, 6) <> "Z"
    end
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
