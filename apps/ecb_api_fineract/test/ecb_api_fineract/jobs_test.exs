defmodule ECBApiFineract.JobsTest do
  @moduledoc """
  The scheduler jobs beyond the answers recorded from Fineract (those are in `ScenariosTest`): the list of jobs,
  running one and its history, and a job with no code behind it being refused.
  """
  use ECBApiFineract.ApiCase

  defp send_json(method, path, body \\ nil),
    do: call(method, "/api" <> path, auth: admin(), body: body)

  test "the jobs Fineract ships with are listed, with the code behind them known by short name" do
    conn = send_json(:get, "/v1/jobs")
    assert conn.status == 200
    jobs = body(conn)
    assert length(jobs) == 41

    assert %{
             "jobId" => 16,
             "displayName" => "Add Periodic Accrual Transactions",
             "active" => true
           } =
             Enum.find(jobs, &(&1["shortName"] == "ACC_APTR"))

    assert body(send_json(:get, "/v1/jobs/short-name/ACC_APTR"))["jobId"] == 16
  end

  test "a job that has run has its run in the history, and the job shows its last run" do
    assert body(send_json(:get, "/v1/jobs/16"))["lastRunHistory"] == nil

    run = send_json(:post, "/v1/jobs/16?command=executeJob", %{})
    assert run.status == 202

    assert %{
             "totalFilteredRecords" => 1,
             "pageItems" => [%{"status" => "success", "version" => 1}]
           } =
             body(send_json(:get, "/v1/jobs/16/runhistory"))

    assert %{"status" => "success", "triggerType" => "application"} =
             body(send_json(:get, "/v1/jobs/short-name/ACC_APTR"))["lastRunHistory"]
  end

  test "a job with no code behind it is refused, not pretended" do
    conn = send_json(:post, "/v1/jobs/19?command=executeJob", %{})
    assert conn.status == 403

    assert [%{"userMessageGlobalisationCode" => "error.msg.scheduler.job.not.supported.yet"}] =
             body(conn)["errors"]

    assert body(send_json(:get, "/v1/jobs/19/runhistory"))["totalFilteredRecords"] == 0
  end

  describe "the scheduler" do
    alias ECBPlatform.{Scheduler, TenantRepo}

    defp next_run(short_name) do
      [[time]] =
        TenantRepo.query!("SELECT next_run_time FROM job WHERE short_name = $1", [short_name]).rows

      time && NaiveDateTime.truncate(time, :second)
    end

    test "gives a job its next time first, and runs it once that has come" do
      noon = ~N[2024-05-01 12:00:00]

      # the first look only sets the times, nothing runs
      assert Scheduler.run_due(noon) == []
      assert next_run("ACC_APTR") == ~N[2024-05-02 00:02:00]
      assert next_run("LA_ARAG") == ~N[2024-05-02 00:01:00]
      assert body(send_json(:get, "/v1/jobs/16/runhistory"))["totalFilteredRecords"] == 0

      # a job that has no code behind it, or is switched off, is left alone
      assert next_run("SA_AANF") == nil
      assert next_run("BDT_INC1") == nil

      # before the time nothing runs; after it the jobs due run, those of higher priority first
      assert Scheduler.run_due(~N[2024-05-02 00:01:30]) == [
               {"apitest", "LA_UNPA"},
               {"apitest", "LA_ARAG"},
               {"apitest", "LA_OPEN"},
               {"apitest", "LA_DECL"},
               {"apitest", "ACC_AATR"}
             ]

      assert next_run("LA_ARAG") == ~N[2024-05-03 00:01:00]
      assert next_run("ACC_APTR") == ~N[2024-05-02 00:02:00]

      assert %{"status" => "success", "triggerType" => "cron"} =
               body(send_json(:get, "/v1/jobs/short-name/LA_ARAG"))["lastRunHistory"]

      # a night that was missed runs the job once, not once per firing
      assert Scheduler.run_due(~N[2024-05-09 08:00:00]) == [
               {"apitest", "LA_UNPA"},
               {"apitest", "LA_ARAG"},
               {"apitest", "LA_OPEN"},
               {"apitest", "LA_DECL"},
               {"apitest", "ACC_AATR"},
               {"apitest", "ACC_APTR"}
             ]

      assert next_run("ACC_APTR") == ~N[2024-05-10 00:02:00]
    end

    test "does not start a job that is running" do
      Scheduler.run_due(~N[2024-05-01 12:00:00])
      TenantRepo.query!("UPDATE job SET currently_running = true WHERE short_name = 'LA_ARAG'")

      TenantRepo.query!(
        "UPDATE job SET previous_run_start_time = now() AT TIME ZONE 'UTC' WHERE short_name = 'LA_ARAG'"
      )

      assert {"apitest", "LA_ARAG"} not in Scheduler.run_due(~N[2024-05-02 01:00:00])

      assert body(send_json(:get, "/v1/jobs/short-name/LA_ARAG/runhistory"))[
               "totalFilteredRecords"
             ] == 0
    end
  end

  test "only a signed-in user may read or run a job" do
    assert call(:get, "/api/v1/jobs").status == 401
    assert call(:post, "/api/v1/jobs/16?command=executeJob", body: %{}).status == 401
  end
end
