defmodule ECoreBank.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Dependencies listed here are available only for this umbrella root, and are
  # development and quality tooling only. Application dependencies belong in
  # each app's own mix.exs.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # Runs each app's own `setup` alias (create database, migrate, build assets).
      setup: ["deps.get", "cmd mix setup"],
      # The same checks CI runs. Run this before pushing.
      "ecb.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow --root apps/ecb_web --exit Low",
        "deps.audit",
        "test"
      ]
    ]
  end

  # One release containing every app. Add an app here when it is created.
  defp releases do
    [
      e_core_bank: [
        applications: [
          ecb_money: :permanent,
          ecb_platform: :permanent,
          ecb_org: :permanent,
          ecb_ledger: :permanent,
          ecb_catalog: :permanent,
          ecb_api_fineract: :permanent,
          ecb_web: :permanent
        ]
      ]
    ]
  end
end
