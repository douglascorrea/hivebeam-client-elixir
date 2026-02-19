defmodule HivebeamClient.EventTest do
  use ExUnit.Case, async: true

  alias HivebeamClient.Event

  test "decodes valid event payload" do
    raw = %{
      "gateway_session_key" => "hbs_123",
      "seq" => 7,
      "ts" => "2026-02-19T10:00:00.000Z",
      "kind" => "prompt_completed",
      "source" => "gateway",
      "payload" => %{"request_id" => "r-1"}
    }

    assert {:ok, event} = Event.decode(raw)
    assert event.gateway_session_key == "hbs_123"
    assert event.seq == 7
    assert event.kind == "prompt_completed"
    assert event.payload["request_id"] == "r-1"
  end

  test "fails when required fields are missing" do
    assert {:error, error} = Event.decode(%{"seq" => 1})
    assert error.type == :decode_error
  end
end
