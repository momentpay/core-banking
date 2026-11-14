%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["apps/*/lib/", "apps/*/test/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      checks: %{
        disabled: [
          # Too noisy for Phoenix-generated components and test support modules.
          {Credo.Check.Design.AliasUsage, []},
          # Error modules are named for the business condition (NoAuthorization, CommandNotFound), not by one prefix.
          {Credo.Check.Consistency.ExceptionNames, []}
        ]
      }
    }
  ]
}
