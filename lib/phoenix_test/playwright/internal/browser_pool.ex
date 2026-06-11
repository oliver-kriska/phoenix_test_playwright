defmodule PhoenixTest.Playwright.BrowserPool do
  @moduledoc """
  Reuses browsers across test suites.
  This limits memory usage and is useful when running feature tests together with regular tests
  (high ExUnit `max_cases` concurrency such as the default: 2x number of CPU cores).

  Pools are defined up front.
  Browsers are launched lazily.
  """

  use GenServer

  alias __MODULE__, as: State
  alias PhoenixTest.Playwright.Config

  defstruct [
    :id,
    :size,
    :config,
    available: [],
    in_use: %{},
    waiting: [],
    launch_count: 0
  ]

  @type pool_id :: atom()
  @type browser_id :: binary()

  ## Public

  @spec checkout(pool_id()) :: browser_id()
  def checkout(pool) do
    timeout = Config.global(:browser_pool_checkout_timeout)
    GenServer.call(pool, :checkout, timeout)
  end

  ## Internal

  @doc false
  def start_link(opts) do
    {id, opts} = Keyword.pop!(opts, :id)
    {size, opts} = Keyword.pop(opts, :size, ceil(System.schedulers_online() / 2))

    GenServer.start_link(__MODULE__, %State{id: id, size: size, config: opts}, name: id)
  end

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:checkout, from, state) do
    cond do
      not Enum.empty?(state.available) ->
        browser_id = hd(state.available)
        state = do_checkout(state, from, browser_id)
        {:reply, browser_id, state}

      map_size(state.in_use) < state.size ->
        {browser, state} = launch(state)
        state = do_checkout(state, from, browser.guid)
        {:reply, browser.guid, state}

      true ->
        state = Map.update!(state, :waiting, &(&1 ++ [from]))
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find_value(state.in_use, fn {browser_id, tracked} -> tracked == {pid, ref} and browser_id end) do
      nil -> {:noreply, state}
      browser_id -> {:noreply, do_checkin(state, browser_id)}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    timeout = Config.global(:timeout)

    for browser_id <- state.available ++ Map.keys(state.in_use) do
      spawn(fn -> PlaywrightEx.Browser.close(browser_id, timeout: timeout) end)
    end
  end

  @doc false
  defdelegate launch_browser!(config), to: PhoenixTest.Playwright.Browser

  defp launch(state) do
    config = state.config |> Config.validate!() |> Keyword.take(Config.setup_all_keys())
    {config, state} = maybe_put_connection(config, state)
    {launch_browser!(config), state}
  end

  # With `connection_per_browser` enabled, each pooled browser gets its own
  # PlaywrightEx instance (connection + node.js server). Downstream calls find
  # the right connection via guid routing (`PlaywrightEx.GuidRouter`), so only
  # the browser launch needs an explicit `:connection`.
  defp maybe_put_connection(config, state) do
    if Config.global(:connection_per_browser) do
      name = Module.concat(state.id, "Playwright#{state.launch_count}")
      opts = Config.global() |> PhoenixTest.Playwright.Supervisor.playwright_opts() |> Keyword.put(:name, name)

      case DynamicSupervisor.start_child(PhoenixTest.Playwright.ConnectionsSupervisor, {PlaywrightEx.Supervisor, opts}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      connection = PlaywrightEx.Supervisor.connection_name(name)
      {Keyword.put(config, :connection, connection), %{state | launch_count: state.launch_count + 1}}
    else
      {config, state}
    end
  end

  defp do_checkout(state, from, browser_id) do
    {from_pid, _tag} = from

    state
    |> Map.update!(:available, &(&1 -- [browser_id]))
    |> Map.update!(:in_use, &Map.put(&1, browser_id, {from_pid, Process.monitor(from_pid)}))
  end

  defp do_checkin(state, browser_id) do
    {{_from_pid, ref}, in_use} = Map.pop(state.in_use, browser_id)
    Process.demonitor(ref, [:flush])
    state = %{state | in_use: in_use, available: [browser_id | state.available]}

    case state.waiting do
      [from | rest] ->
        GenServer.reply(from, browser_id)
        %{do_checkout(state, from, browser_id) | waiting: rest}

      _ ->
        state
    end
  end
end
