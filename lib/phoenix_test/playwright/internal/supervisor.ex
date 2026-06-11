defmodule PhoenixTest.Playwright.Supervisor do
  @moduledoc """
  Supervises the Playwright connection and browser pools.

  Supports two transport modes:
  - **Local** (default): Spawns a local Node.js Playwright driver via Erlang Port
  - **Remote**: Connects to a remote Playwright server via WebSocket when `ws_endpoint` is configured
  """

  use Supervisor

  alias PhoenixTest.Playwright.Config

  def start_link(config \\ Config.global()) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    config = Config.validate!(config)

    children = [
      {PlaywrightEx.Supervisor, playwright_opts(config)},
      {DynamicSupervisor, strategy: :one_for_one, name: PhoenixTest.Playwright.ConnectionsSupervisor},
      PhoenixTest.Playwright.BrowserPoolSupervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  # Also used by BrowserPool to start one PlaywrightEx instance per browser
  # (see the `connection_per_browser` config option).
  def playwright_opts(config) do
    base = Keyword.take(config, ~w(timeout js_logger)a)

    case config[:ws_endpoint] do
      nil -> Keyword.put(base, :executable, Config.executable())
      url -> Keyword.put(base, :ws_endpoint, ws_endpoint_with_browser(url, config))
    end
  end

  defp ws_endpoint_with_browser(url, config) do
    url
    |> URI.parse()
    |> URI.append_query("browser=#{config[:browser]}")
    |> URI.to_string()
  end
end
