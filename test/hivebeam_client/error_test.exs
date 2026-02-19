defmodule HivebeamClient.ErrorTest do
  use ExUnit.Case, async: true

  alias HivebeamClient.Error

  test "maps 401/404/422/500 into typed errors" do
    assert Error.from_http(401, %{"error" => "unauthorized"}).type == :unauthorized
    assert Error.from_http(404, %{"error" => "session_not_found"}).type == :not_found
    assert Error.from_http(422, %{"error" => "text is required"}).type == :invalid_request
    assert Error.from_http(500, %{"error" => "boom"}).type == :server_error
  end

  test "transport errors are typed" do
    error = Error.from_transport(:timeout)
    assert error.type == :transport_error
    assert error.details == :timeout
  end
end
