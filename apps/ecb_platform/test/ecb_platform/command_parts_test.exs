defmodule ECBPlatform.CommandPartsTest do
  use ExUnit.Case, async: true

  alias ECBPlatform.Commands.{Command, Errors, Result, ResultType}
  alias ECBPlatform.Security.User

  describe "ResultType" do
    test "uses Fineract's status codes" do
      assert ResultType.to_int(:invalid) == 0
      assert ResultType.to_int(:processed) == 1
      assert ResultType.to_int(:awaiting_approval) == 2
      assert ResultType.to_int(:rejected) == 3
      assert ResultType.to_int(:under_processing) == 4
      assert ResultType.to_int(:error) == 5
    end

    test "round trips, and unknown codes are invalid" do
      for type <- [:processed, :awaiting_approval, :rejected, :under_processing, :error] do
        assert type |> ResultType.to_int() |> ResultType.from_int() == type
      end

      assert ResultType.from_int(99) == :invalid
      assert ResultType.from_int(nil) == :invalid
    end
  end

  describe "Command" do
    test "the permission is ACTION_ENTITY" do
      assert Command.task_permission(Command.new("CREATE", "CLIENT")) == "CREATE_CLIENT"

      assert Command.task_permission(Command.new("ACTIVATE", "SAVINGSACCOUNT")) ==
               "ACTIVATE_SAVINGSACCOUNT"
    end

    test "the body is kept as received and parsed on demand" do
      json = ~s({"firstname": "Ada",  "active":true})
      command = Command.new("CREATE", "CLIENT", json: json)
      assert command.json == json
      assert Command.stored_json(command) == json
      assert Command.data(command) == %{"firstname" => "Ada", "active" => true}
    end

    test "a missing or empty body is an empty map, stored as {}" do
      assert Command.data(Command.new("CREATE", "CLIENT")) == %{}
      assert Command.data(Command.new("CREATE", "CLIENT", json: "")) == %{}
      assert Command.stored_json(Command.new("CREATE", "CLIENT")) == "{}"
    end

    test "unknown fields are refused" do
      assert_raise KeyError, fn -> Command.new("CREATE", "CLIENT", nonsense: 1) end
    end
  end

  describe "Result" do
    test "the API map uses Fineract's field names and leaves out unset fields" do
      result = Result.new(resource_id: 5, office_id: 1, client_id: 9, changes: %{"name" => "x"})

      assert Result.to_api_map(result) == %{
               "resourceId" => 5,
               "officeId" => 1,
               "clientId" => 9,
               "changes" => %{"name" => "x"}
             }
    end

    test "resource/2 also reports the id as text, as Fineract's resourceResult does" do
      assert Result.to_api_map(Result.resource(5, office_id: 1)) ==
               %{"resourceId" => 5, "resourceIdentifier" => "5", "officeId" => 1}
    end

    test "every field has a Fineract name" do
      full =
        Result.new(
          command_id: 1,
          office_id: 2,
          group_id: 3,
          client_id: 4,
          loan_id: 5,
          savings_id: 6,
          resource_id: 7,
          subresource_id: 8,
          transaction_id: "t",
          changes: %{},
          resource_identifier: "r",
          product_id: 9,
          gsim_id: 10,
          glim_id: 11,
          resource_external_id: "e1",
          subresource_external_id: "e2",
          loan_external_id: "e3",
          credit_bureau_report_data: %{}
        )

      assert full |> Result.to_api_map() |> Map.keys() |> Enum.sort() ==
               ~w(changes clientId commandId creditBureauReportData glimId groupId gsimId loanExternalId loanId officeId productId resourceExternalId resourceId resourceIdentifier savingsId subResourceExternalId subResourceId transactionId)
    end

    test "an empty result is an empty map" do
      assert Result.to_api_map(Result.new()) == %{}
      assert Result.to_json(Result.new()) == "{}"
    end
  end

  describe "User permissions" do
    test "ALL_FUNCTIONS can do anything and is a checker super user" do
      admin = User.new(1, "admin", ["ALL_FUNCTIONS"])
      assert User.has_permission?(admin, "ANYTHING_AT_ALL")
      assert User.checker_super_user?(admin)
      refute User.has_not_permission_for_any_of?(admin, ["X"])
    end

    test "otherwise only the specific codes" do
      user = User.new(2, "clerk", ["CREATE_CLIENT"])
      assert User.has_permission?(user, "CREATE_CLIENT")
      refute User.has_permission?(user, "DELETE_CLIENT")
      refute User.checker_super_user?(user)
      assert User.has_not_permission_for_any_of?(user, ["DELETE_CLIENT", "UPDATE_CLIENT"])
      refute User.has_not_permission_for_any_of?(user, ["DELETE_CLIENT", "CREATE_CLIENT"])
    end

    test "the checker permission is the task code plus _CHECKER" do
      assert User.checker_permission("CREATE_CLIENT") == "CREATE_CLIENT_CHECKER"
      assert User.checker_super_user?(User.new(3, "boss", ["CHECKER_SUPER_USER"]))
    end
  end

  describe "Errors" do
    test "map to the HTTP statuses Fineract answers with" do
      assert Errors.http_status(%Errors.NoAuthorization{permission: "X"}) == 403
      assert Errors.http_status(%Errors.CheckerOnlyInitiation{}) == 403
      assert Errors.http_status(%Errors.DuplicatePendingSubmission{}) == 403
      assert Errors.http_status(%Errors.PermissionNotFound{}) == 404
      assert Errors.http_status(%Errors.CommandNotFound{}) == 404
      assert Errors.http_status(%Errors.CommandNotAwaitingApproval{}) == 404
      assert Errors.http_status(%Errors.UnsupportedCommand{}) == 400
      assert Errors.http_status(%Errors.RollbackNotApproved{}) == 200
      assert Errors.http_status(%Errors.IdempotentUnderProcessing{}) == 409
      assert Errors.http_status(%Errors.IdempotentSucceeded{}) == 200
      assert Errors.http_status(%RuntimeError{message: "x"}) == 500
    end

    test "the API body has Fineract's fields" do
      body = Errors.to_api_map(%Errors.NoAuthorization{permission: "CREATE_CLIENT"})

      assert %{
               "developerMessage" => "User has no authority to: CREATE_CLIENT",
               "httpStatusCode" => "403",
               "defaultUserMessage" => _,
               "userMessageGlobalisationCode" => "error.msg.platform.no_authorization",
               "errors" => []
             } = body
    end

    test "NoAuthorization has a message built from the permission" do
      assert Exception.message(Errors.NoAuthorization.exception(permission: "DELETE_LOAN")) ==
               "User has no authority to: DELETE_LOAN"
    end
  end
end
