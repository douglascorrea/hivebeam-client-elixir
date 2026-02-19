defmodule HivebeamClient.Transport.WsTest do
  use ExUnit.Case, async: true

  alias HivebeamClient.Config
  alias HivebeamClient.Transport.WS

  test "updates cursor and forwards event frames" do
    config = Config.new!(base_url: "http://127.0.0.1:8080", token: "t")

    state = %{
      owner: self(),
      config: config,
      session_key: "hbs_1",
      after_seq: 1,
      reconnect_ms: 100
    }

    payload = %{
      "type" => "event",
      "data" => %{
        "gateway_session_key" => "hbs_1",
        "seq" => 2,
        "ts" => "2026-02-19T10:00:00.000Z",
        "kind" => "prompt_started",
        "source" => "gateway",
        "payload" => %{}
      }
    }

    assert {:ok, next_state} = WS.handle_frame({:text, Jason.encode!(payload)}, state)
    assert next_state.after_seq == 2

    assert_receive {:hivebeam_ws, :event, %{"seq" => 2}}
    assert_receive {:hivebeam_ws, :frame, %{"type" => "event"}}
  end

  test "encodes attach cast frame" do
    config = Config.new!(base_url: "http://127.0.0.1:8080", token: "t")

    state = %{
      owner: self(),
      config: config,
      session_key: nil,
      after_seq: 0,
      reconnect_ms: 100
    }

    assert {:reply, {:text, frame}, next_state} = WS.handle_cast({:attach, "hbs_2", 4}, state)
    assert next_state.session_key == "hbs_2"
    assert next_state.after_seq == 4

    assert Jason.decode!(frame) == %{
             "type" => "attach",
             "gateway_session_key" => "hbs_2",
             "after_seq" => 4
           }
  end
end
