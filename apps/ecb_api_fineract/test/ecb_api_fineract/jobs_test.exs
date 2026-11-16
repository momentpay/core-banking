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
    conn = send_json(:post, "/v1/jobs/2?command=executeJob", %{})
    assert conn.status == 403

    assert [%{"userMessageGlobalisationCode" => "error.msg.scheduler.job.not.supported.yet"}] =
             body(conn)["errors"]

    assert body(send_json(:get, "/v1/jobs/2/runhistory"))["totalFilteredRecords"] == 0
  end

  test "only a signed-in user may read or run a job" do
    assert call(:get, "/api/v1/jobs").status == 401
    assert call(:post, "/api/v1/jobs/16?command=executeJob", body: %{}).status == 401
  end
end
