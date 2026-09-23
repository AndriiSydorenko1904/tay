defmodule Tay.Dashboard.Standalone.ConfigTest do
  use ExUnit.Case, async: true

  alias Tay.Dashboard.Standalone.Config

  @valid %{"TAY_DASHBOARD_SECRET_KEY_BASE" => String.duplicate("s", 64)}

  test "disables Basic Auth by default" do
    assert {:ok, config} = Config.load(@valid)
    assert config.host == "localhost"
    assert config.port == 4000
    assert config.username == nil
    assert config.password == nil
  end

  test "enables Basic Auth when both credentials are present" do
    environment =
      Map.merge(@valid, %{
        "TAY_DASHBOARD_USERNAME" => "operator",
        "TAY_DASHBOARD_PASSWORD" => "secret"
      })

    assert {:ok, config} = Config.load(environment)
    assert config.username == "operator"
    assert config.password == "secret"
  end

  test "requires paired nonblank credentials and a release secret" do
    assert {:error, message} = Config.load(%{})
    assert message =~ "TAY_DASHBOARD_SECRET_KEY_BASE"

    assert {:error, message} =
             Config.load(Map.put(@valid, "TAY_DASHBOARD_USERNAME", "operator"))

    assert message =~ "provided together"

    assert {:error, message} =
             Config.load(
               Map.merge(@valid, %{
                 "TAY_DASHBOARD_USERNAME" => "operator",
                 "TAY_DASHBOARD_PASSWORD" => " "
               })
             )

    assert message =~ "nonblank"

    assert {:error, message} =
             Config.load(Map.put(@valid, "TAY_DASHBOARD_SECRET_KEY_BASE", "short"))

    assert message =~ "at least 64 bytes"
  end

  test "rejects malformed public endpoint values" do
    assert {:error, message} = Config.load(Map.put(@valid, "TAY_DASHBOARD_PORT", "0"))
    assert message =~ "1 through 65535"

    assert {:error, message} =
             Config.load(Map.put(@valid, "TAY_DASHBOARD_HOST", "https://example.com"))

    assert message =~ "without a scheme"
  end
end
