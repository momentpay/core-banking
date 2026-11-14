defmodule ECBPlatform.Tenancy.Pools do
  @moduledoc """
  Starts and tracks one `ECBPlatform.TenantRepo` connection pool per tenant.

  Pools are started lazily on the first request for a tenant and kept for the life of the
  node. Starts are serialized through this process so two requests for a new tenant never
  start two pools.

  If a tenant's connection details change in the registry, call `stop/1` so the next
  request starts a pool with the new details.
  """
  use GenServer

  alias ECBPlatform.Tenancy.Tenant
  alias ECBPlatform.TenantRepo

  @supervisor ECBPlatform.Tenancy.PoolSupervisor

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, pid}` for the tenant's pool, starting it if needed."
  @spec ensure_started(Tenant.t()) :: {:ok, pid} | {:error, term}
  def ensure_started(%Tenant{} = tenant) do
    GenServer.call(__MODULE__, {:ensure_started, tenant}, 30_000)
  end

  @doc "Stops the pool for a tenant identifier, if one is running."
  @spec stop(String.t()) :: :ok
  def stop(identifier), do: GenServer.call(__MODULE__, {:stop, identifier})

  @impl true
  def init(_opts), do: {:ok, %{pools: %{}, monitors: %{}}}

  @impl true
  def handle_call({:ensure_started, tenant}, _from, state) do
    case Map.get(state.pools, tenant.identifier) do
      pid when is_pid(pid) ->
        {:reply, {:ok, pid}, state}

      nil ->
        opts = [name: nil] ++ Tenant.repo_opts(tenant)

        child_spec = %{
          id: {TenantRepo, tenant.identifier},
          start: {TenantRepo, :start_link, [opts]},
          type: :supervisor,
          restart: :temporary
        }

        case DynamicSupervisor.start_child(@supervisor, child_spec) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            state = %{
              state
              | pools: Map.put(state.pools, tenant.identifier, pid),
                monitors: Map.put(state.monitors, ref, tenant.identifier)
            }

            {:reply, {:ok, pid}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:stop, identifier}, _from, state) do
    case Map.pop(state.pools, identifier) do
      {nil, _pools} ->
        {:reply, :ok, state}

      {pid, pools} ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        {:reply, :ok, %{state | pools: pools}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {identifier, monitors} = Map.pop(state.monitors, ref)
    {:noreply, %{state | pools: Map.delete(state.pools, identifier), monitors: monitors}}
  end
end
