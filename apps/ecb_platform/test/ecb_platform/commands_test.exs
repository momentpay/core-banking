defmodule ECBPlatform.CommandsTest do
  use ECBPlatform.TenantCase

  import Ecto.Query, only: [from: 2]

  alias ECBPlatform.Commands
  alias ECBPlatform.Commands.{Command, CommandSource, Errors, Handlers, ResultType}
  alias ECBPlatform.TestHandlers

  @processed ResultType.to_int(:processed)
  @awaiting ResultType.to_int(:awaiting_approval)
  @rejected ResultType.to_int(:rejected)
  @error ResultType.to_int(:error)

  setup do
    Handlers.register("WIDGET", "CREATE", TestHandlers.Succeed)
    Handlers.register("WIDGET", "FAIL", TestHandlers.Fail)
    Handlers.register("WIDGET", "RAISE", TestHandlers.Raise)
    Handlers.register("WIDGET", "DRYRUN", TestHandlers.DryRun)
    Handlers.register("WIDGET", "GARBAGE", TestHandlers.Garbage)
    Application.delete_env(:ecb_platform, :command_hooks)

    on_exit(fn ->
      for action <- ~w(CREATE FAIL RAISE DRYRUN GARBAGE),
          do: Handlers.unregister("WIDGET", action)

      Application.delete_env(:ecb_platform, :command_hooks)
    end)

    admin = create_user("admin", ["ALL_FUNCTIONS"])
    %{admin: admin}
  end

  defp cmd(action, opts \\ []) do
    Command.new(
      action,
      "WIDGET",
      Keyword.merge(
        [
          json: ~s({"name":"alpha"}),
          href: "/widgets",
          idempotency_key: "key-#{System.unique_integer([:positive])}"
        ],
        opts
      )
    )
  end

  defp source(id), do: Commands.get(id)

  defp only_source,
    do: TenantRepo.one!(from(c in CommandSource, order_by: [desc: c.id], limit: 1))

  describe "permissions" do
    test "a user without the permission is refused and nothing is stored" do
      user = create_user("clerk", [])

      assert {:error, %Errors.NoAuthorization{permission: "CREATE_WIDGET"}} =
               Commands.execute(cmd("CREATE"), user)

      assert TenantRepo.aggregate(CommandSource, :count) == 0
      assert TestHandlers.written() == []
    end

    test "the specific permission is enough" do
      user = create_user("clerk", ["CREATE_WIDGET"])
      assert {:ok, _} = Commands.execute(cmd("CREATE"), user)
    end

    test "ALL_FUNCTIONS is enough", %{admin: admin} do
      assert {:ok, _} = Commands.execute(cmd("CREATE"), admin)
    end

    test "an unknown permission code is reported, not crashed on", %{admin: admin} do
      # under maker-checker the pipeline looks the task's permission row up; there is none for this one
      enable_maker_checker()
      Handlers.register("WIDGET", "UNKNOWN", TestHandlers.Succeed)
      on_exit(fn -> Handlers.unregister("WIDGET", "UNKNOWN") end)

      assert {:error, %Errors.PermissionNotFound{code: "UNKNOWN_WIDGET"}} =
               Commands.execute(cmd("UNKNOWN"), admin)
    end
  end

  describe "a successful command" do
    test "is stored as processed with its result, in the same transaction as the handler's work",
         %{admin: admin} do
      assert {:ok, result} = Commands.execute(cmd("CREATE", entity_id: nil), admin)
      assert result.office_id == 1 and result.client_id == 7
      assert TestHandlers.written() == ["test-widget-alpha"]

      stored = only_source()
      assert stored.status == @processed
      assert stored.result_status_code == 200
      assert stored.maker_id == admin.id
      assert stored.action_name == "CREATE" and stored.entity_name == "WIDGET"
      assert stored.command_as_json == ~s({"name":"alpha"})
      assert stored.office_id == 1 and stored.client_id == 7
      assert stored.resource_id == result.resource_id

      assert %{"resourceId" => _, "officeId" => 1, "clientId" => 7, "changes" => %{"name" => "x"}} =
               Jason.decode!(stored.result)

      assert stored.made_on_date_utc
    end

    test "a missing body is stored as {}", %{admin: admin} do
      assert {:ok, _} = Commands.execute(cmd("CREATE", json: nil), admin)
      assert only_source().command_as_json == "{}"
    end

    test "a generated idempotency key is used when the caller gives none", %{admin: admin} do
      assert {:ok, _} = Commands.execute(cmd("CREATE", idempotency_key: nil), admin)
      assert String.length(only_source().idempotency_key) == 36
    end

    test "records the ids it was given up front", %{admin: admin} do
      command = cmd("CREATE", office_id: 3, loan_id: 5, savings_id: 6, href: "/widgets/9")
      assert {:ok, _} = Commands.execute(command, admin)
      assert only_source().api_get_url == "/widgets/9"
    end
  end

  describe "a command that fails" do
    test "is rolled back, recorded as an error, and the error is returned", %{admin: admin} do
      assert {:error, %Errors.UnsupportedCommand{}} = Commands.execute(cmd("FAIL"), admin)
      assert TestHandlers.written() == []

      stored = only_source()
      assert stored.status == @error
      assert stored.result_status_code == 400

      assert %{"httpStatusCode" => "400", "developerMessage" => message} =
               Jason.decode!(stored.result)

      assert message =~ "on purpose"
    end

    test "that raises is rolled back and recorded too", %{admin: admin} do
      assert {:error, %RuntimeError{message: "handler blew up"}} =
               Commands.execute(cmd("RAISE"), admin)

      assert TestHandlers.written() == []
      assert only_source().status == @error
      assert only_source().result_status_code == 500
    end

    test "with no registered handler is an unsupported command", %{admin: admin} do
      assert {:error, %Errors.UnsupportedCommand{detail: "no handler registered"}} =
               Commands.execute(cmd("NOHANDLER"), admin)

      assert only_source().status == @error
    end

    test "whose handler returns something that is not a result is an error", %{admin: admin} do
      assert {:error, %RuntimeError{message: message}} = Commands.execute(cmd("GARBAGE"), admin)
      assert message =~ "returned :not_a_result"
    end
  end

  describe "idempotency" do
    test "repeating a request that succeeded returns the stored outcome and does not run it again",
         %{admin: admin} do
      command = cmd("CREATE", idempotency_key: "same-key")
      assert {:ok, first} = Commands.execute(command, admin)

      assert {:error,
              %Errors.IdempotentSucceeded{command_source: stored, idempotency_key: "same-key"}} =
               Commands.execute(command, admin)

      assert Jason.decode!(stored.result)["resourceId"] == first.resource_id
      assert TestHandlers.written() == ["test-widget-alpha"]
      assert TenantRepo.aggregate(CommandSource, :count) == 1
    end

    test "the same key on a different action or entity is a different request", %{admin: admin} do
      assert {:ok, _} = Commands.execute(cmd("CREATE", idempotency_key: "shared"), admin)
      Handlers.register("OTHER", "CREATE", TestHandlers.Succeed)
      on_exit(fn -> Handlers.unregister("OTHER", "CREATE") end)

      assert {:ok, _} =
               Commands.execute(
                 Command.new("CREATE", "OTHER", json: "{}", href: "/o", idempotency_key: "shared"),
                 admin
               )
    end

    test "repeating a request that failed returns the stored failure, unless the caller is retrying",
         %{admin: admin} do
      command = cmd("FAIL", idempotency_key: "will-fail")
      assert {:error, %Errors.UnsupportedCommand{}} = Commands.execute(command, admin)

      assert {:error, %Errors.IdempotentFailed{command_source: stored}} =
               Commands.execute(command, admin)

      assert stored.result_status_code == 400
      assert Errors.http_status(%Errors.IdempotentFailed{command_source: stored}) == 400

      # a retry continues the stored command (no second row) and runs the handler again
      assert {:error, %Errors.UnsupportedCommand{}} =
               Commands.execute(command, admin, retry: true)

      assert TenantRepo.aggregate(CommandSource, :count) == 1
    end

    test "a request still being processed answers 409", %{admin: admin} do
      TenantRepo.insert_all("m_portfolio_command_source", [
        %{
          action_name: "CREATE",
          entity_name: "WIDGET",
          api_get_url: "/widgets",
          command_as_json: "{}",
          maker_id: admin.id,
          made_on_date_utc: DateTime.utc_now(),
          status: ResultType.to_int(:under_processing),
          idempotency_key: "in-flight",
          is_sanitized: false
        }
      ])

      assert {:error, %Errors.IdempotentUnderProcessing{} = error} =
               Commands.execute(cmd("CREATE", idempotency_key: "in-flight"), admin)

      assert Errors.http_status(error) == 409
      assert TestHandlers.written() == []
    end

    test "a concurrent duplicate that loses the race for the unique key answers 409", %{
      admin: admin
    } do
      key = "race-key"

      results =
        1..8
        |> Task.async_stream(
          fn _ ->
            # each task needs the tenant's pool, which is process-local state
            {:ok, pool} =
              ECBPlatform.Tenancy.Pools.ensure_started(ECBPlatform.TenantCase.tenant())

            TenantRepo.put_dynamic_repo(pool)
            Commands.execute(cmd("CREATE", idempotency_key: key), admin)
          end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, %Errors.IdempotentUnderProcessing{}} -> true
               {:error, %Errors.IdempotentSucceeded{}} -> true
             end)

      assert TestHandlers.written() == ["test-widget-alpha"]
    end
  end

  describe "maker-checker" do
    setup do
      enable_maker_checker()
      put_permission("CREATE_WIDGET", maker_checker: true)
      maker = create_user("maker", ["CREATE_WIDGET"])
      checker = create_user("checker", ["CREATE_WIDGET_CHECKER"])
      %{maker: maker, checker: checker}
    end

    test "a maker's command is validated, rolled back, and parked awaiting approval", %{
      maker: maker
    } do
      assert {:error, %Errors.RollbackNotApproved{command_id: id}} =
               Commands.execute(cmd("CREATE"), maker)

      assert TestHandlers.written() == []

      parked = source(id)
      assert parked.status == @awaiting
      assert parked.result_status_code == 200
      assert parked.maker_id == maker.id
      assert is_nil(parked.checker_id)
      assert Errors.http_status(%Errors.RollbackNotApproved{}) == 200
    end

    test "a checker approves it and the work is applied exactly once", %{
      maker: maker,
      checker: checker
    } do
      {:error, %Errors.RollbackNotApproved{command_id: id}} =
        Commands.execute(cmd("CREATE"), maker)

      assert {:ok, result} = Commands.approve(id, checker)
      assert result.command_id == id
      assert TestHandlers.written() == ["test-widget-alpha"]

      done = source(id)
      assert done.status == @processed
      assert done.checker_id == checker.id
      assert done.maker_id == maker.id
      assert done.checked_on_date_utc
      assert done.result_status_code == 200

      assert {:error, %Errors.CommandNotAwaitingApproval{}} = Commands.approve(id, checker)
    end

    test "the maker cannot check their own command", %{maker: maker} do
      checker_too = create_user("both", ["CREATE_WIDGET", "CREATE_WIDGET_CHECKER"])

      {:error, %Errors.RollbackNotApproved{command_id: id}} =
        Commands.execute(cmd("CREATE"), checker_too)

      assert {:error, %Errors.UnsupportedCommand{detail: "Can not be checked by the same user."}} =
               Commands.approve(id, checker_too)

      assert source(id).status == @awaiting
      _ = maker
    end

    test "unless the tenant allows the same user to make and check" do
      enable_maker_checker(same_maker_checker: true)
      both = create_user("both", ["CREATE_WIDGET", "CREATE_WIDGET_CHECKER"])

      {:error, %Errors.RollbackNotApproved{command_id: id}} =
        Commands.execute(cmd("CREATE"), both)

      assert {:ok, _} = Commands.approve(id, both)
    end

    test "a user who is not a checker cannot approve", %{maker: maker} do
      {:error, %Errors.RollbackNotApproved{command_id: id}} =
        Commands.execute(cmd("CREATE"), maker)

      other = create_user("other", ["CREATE_WIDGET"])
      assert {:error, %Errors.NoAuthorization{}} = Commands.approve(id, other)
    end

    test "a checker super user's own command runs at once and records them as checker", %{
      admin: admin
    } do
      assert {:ok, _} = Commands.execute(cmd("CREATE"), admin)
      stored = only_source()
      assert stored.status == @processed
      assert stored.checker_id == admin.id
      assert TestHandlers.written() == ["test-widget-alpha"]
    end

    test "an identical command already waiting is refused", %{maker: maker} do
      command = cmd("CREATE", entity_id: 12, idempotency_key: nil)
      assert {:error, %Errors.RollbackNotApproved{}} = Commands.execute(command, maker)

      assert {:error,
              %Errors.DuplicatePendingSubmission{action_name: "CREATE", entity_name: "WIDGET"}} =
               Commands.execute(command, maker)

      assert TenantRepo.aggregate(CommandSource, :count) == 1
    end

    test "a different body is not a duplicate", %{maker: maker} do
      assert {:error, %Errors.RollbackNotApproved{}} =
               Commands.execute(cmd("CREATE", entity_id: 12, idempotency_key: nil), maker)

      different = cmd("CREATE", entity_id: 12, idempotency_key: nil, json: ~s({"name":"beta"}))
      assert {:error, %Errors.RollbackNotApproved{}} = Commands.execute(different, maker)
    end

    test "a checker-only user repeating the command approves the pending one", %{
      maker: maker,
      checker: checker
    } do
      command = cmd("CREATE", entity_id: 12, idempotency_key: nil)
      {:error, %Errors.RollbackNotApproved{command_id: id}} = Commands.execute(command, maker)

      assert {:ok, _} = Commands.execute(command, checker)
      assert source(id).status == @processed
      assert source(id).checker_id == checker.id
    end

    test "a checker-only user with nothing pending cannot start a command", %{checker: checker} do
      assert {:error, %Errors.CheckerOnlyInitiation{permission: "CREATE_WIDGET"}} =
               Commands.execute(cmd("CREATE", entity_id: 12), checker)
    end

    test "rejecting records the checker and keeps the work undone", %{
      maker: maker,
      checker: checker
    } do
      {:error, %Errors.RollbackNotApproved{command_id: id}} =
        Commands.execute(cmd("CREATE"), maker)

      assert {:ok, ^id} = Commands.reject(id, checker)
      assert source(id).status == @rejected
      assert source(id).checker_id == checker.id
      assert TestHandlers.written() == []
      assert {:error, %Errors.CommandNotAwaitingApproval{}} = Commands.reject(id, checker)
    end

    test "deleting removes a waiting command", %{maker: maker, checker: checker} do
      {:error, %Errors.RollbackNotApproved{command_id: id}} =
        Commands.execute(cmd("CREATE"), maker)

      assert {:ok, ^id} = Commands.delete(id, checker)
      assert source(id) == nil
    end

    test "approving a command that does not exist", %{checker: checker} do
      assert {:error, %Errors.CommandNotFound{command_id: 999_999}} =
               Commands.approve(999_999, checker)
    end

    test "a task whose permission is not flagged for maker-checker is not held", %{admin: _admin} do
      put_permission("CREATE_WIDGET", maker_checker: false)
      maker = create_user("maker2", ["CREATE_WIDGET"])
      assert {:ok, _} = Commands.execute(cmd("CREATE"), maker)
    end

    test "global maker-checker off means nothing is held even for flagged permissions" do
      TenantRepo.query!("UPDATE c_configuration SET enabled = false WHERE name = 'maker-checker'")
      maker = create_user("maker3", ["CREATE_WIDGET"])
      assert {:ok, _} = Commands.execute(cmd("CREATE"), maker)
    end
  end

  describe "a dry run (rollback_transaction)" do
    test "is held for approval even without maker-checker, unless a checker super user runs it",
         %{admin: admin} do
      put_permission("DRYRUN_WIDGET", maker_checker: false)
      user = create_user("planner", ["DRYRUN_WIDGET"])

      assert {:error, %Errors.RollbackNotApproved{}} = Commands.execute(cmd("DRYRUN"), user)
      assert TestHandlers.written() == []

      assert {:ok, _} = Commands.execute(cmd("DRYRUN", json: ~s({"name":"approved"})), admin)
      assert TestHandlers.written() == ["test-widget-approved"]
    end
  end

  describe "hooks" do
    test "are told about success and about failure, and cannot change the outcome", %{
      admin: admin
    } do
      Process.register(self(), :hook_test)

      Application.put_env(:ecb_platform, :command_hooks, [
        TestHandlers.BrokenHook,
        TestHandlers.Hook
      ])

      assert {:ok, result} = Commands.execute(cmd("CREATE"), admin)
      assert_receive {:success, "CREATE", ^result}

      failing = cmd("FAIL", json: ~s({"name":"beta"}))
      assert {:error, %Errors.UnsupportedCommand{} = error} = Commands.execute(failing, admin)
      assert_receive {:error, "FAIL", ^error}
    end
  end

  describe "Handlers registry" do
    test "reports registrations and unsupported commands" do
      assert {:ok, TestHandlers.Succeed} = Handlers.fetch("WIDGET", "CREATE")
      assert {:error, %Errors.UnsupportedCommand{}} = Handlers.fetch("WIDGET", "NOPE")
      assert {{"WIDGET", "CREATE"}, TestHandlers.Succeed} in Handlers.all()
    end
  end
end
