defmodule TimelessUI.TelemetryDataPlane.DialEndpointTest do
  use ExUnit.Case, async: true

  alias TimelessUI.TelemetryDataPlane.Process, as: DataPlaneProcess

  test "all-interfaces binds dial loopback; explicit hosts pass through" do
    assert DataPlaneProcess.dial_endpoint("0.0.0.0:8428") == "http://127.0.0.1:8428"
    assert DataPlaneProcess.dial_endpoint("[::]:8428") == "http://[::1]:8428"
    assert DataPlaneProcess.dial_endpoint("127.0.0.1:8428") == "http://127.0.0.1:8428"
    assert DataPlaneProcess.dial_endpoint("10.0.0.5:8428") == "http://10.0.0.5:8428"
  end
end
