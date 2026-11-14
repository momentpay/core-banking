defmodule ECBWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ECBWeb.Telemetry,
      # Start to serve requests, typically the last entry.
      ECBWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ECBWeb.Supervisor)
  end

  # Tell Phoenix to update the endpoint configuration whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ECBWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
