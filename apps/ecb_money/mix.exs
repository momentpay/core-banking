defmodule ECBMoney.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecb_money,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # A pure library: no supervision tree, no database, no configuration.
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:decimal, "~> 3.0"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:jason, "~> 1.2", only: :test}
    ]
  end
end
