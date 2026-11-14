defmodule ECBApiFineract.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecb_api_fineract,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # A set of plugs and routes mounted by the web endpoint: no supervision tree of its own.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecb_platform, in_umbrella: true},
      {:ecb_org, in_umbrella: true},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.2"},
      {:ecto_sql, "~> 3.10"}
    ]
  end
end
