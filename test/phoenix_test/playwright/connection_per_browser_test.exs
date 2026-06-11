defmodule PhoenixTest.Playwright.ConnectionPerBrowserTest do
  # async: false — temporarily flips the global `connection_per_browser` config.
  use ExUnit.Case, async: false

  alias PhoenixTest.Playwright.BrowserPool

  @pool :connection_per_browser_test_pool

  setup do
    config = Application.get_env(:phoenix_test, :playwright, [])
    Application.put_env(:phoenix_test, :playwright, Keyword.put(config, :connection_per_browser, true))
    on_exit(fn -> Application.put_env(:phoenix_test, :playwright, config) end)

    start_supervised!({BrowserPool, id: @pool, size: 2})
    :ok
  end

  test "pooled browsers run on separate connections, channel calls route by guid" do
    timeout = PhoenixTest.Playwright.Config.global(:timeout)

    browser_a = BrowserPool.checkout(@pool)
    browser_b = BrowserPool.checkout(@pool)

    default = PlaywrightEx.Supervisor.connection_name()
    connection_a = PlaywrightEx.GuidRouter.route(browser_a, default)
    connection_b = PlaywrightEx.GuidRouter.route(browser_b, default)

    assert connection_a != default
    assert connection_b != default
    assert connection_a != connection_b

    # Full session flow on a non-default connection WITHOUT passing :connection.
    {:ok, context} = PlaywrightEx.Browser.new_context(browser_a, timeout: timeout)
    {:ok, page} = PlaywrightEx.BrowserContext.new_page(context.guid, timeout: timeout)
    frame_id = page.main_frame.guid

    assert {:ok, _} = PlaywrightEx.Frame.goto(frame_id, url: "about:blank", timeout: timeout)

    assert {:ok, "routed"} =
             PlaywrightEx.Frame.evaluate(frame_id,
               expression: "() => 'routed'",
               is_function: true,
               timeout: timeout
             )
  end
end
