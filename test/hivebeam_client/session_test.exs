defmodule HivebeamClient.SessionTest do
  use ExUnit.Case, async: true

  alias HivebeamClient.Config
  alias HivebeamClient.Event
  alias HivebeamClient.Session

  defmodule FakeHTTP do
    def create_session(_config, _attrs),
      do: {:ok, %{"gateway_session_key" => "hbs_test", "last_seq" => 0}}

    def attach(_config, _session_key, _after_seq, _limit),
      do: {:ok, %{"events" => [], "next_after_seq" => 0, "has_more" => false}}

    def prompt(_config, _session_key, _request_id, _text, _timeout),
      do: {:ok, %{"accepted" => true}}

    def cancel(_config, _session_key), do: {:ok, %{"accepted" => true}}
    def approve(_config, _session_key, _approval_ref, _decision), do: {:ok, %{"accepted" => true}}
    def close(_config, _session_key), do: {:ok, %{"closed" => true}}

    def fetch_events(_config, _session_key, after_seq, _limit) when after_seq < 2 do
      {:ok,
       %{
         "events" => [
           event(1, "prompt_started"),
           event(2, "prompt_completed")
         ],
         "next_after_seq" => 2,
         "has_more" => false
       }}
    end

    def fetch_events(_config, _session_key, _after_seq, _limit) do
      {:ok,
       %{"events" => [event(2, "prompt_completed")], "next_after_seq" => 2, "has_more" => false}}
    end

    defp event(seq, kind) do
      %{
        "gateway_session_key" => "hbs_test",
        "seq" => seq,
        "ts" => "2026-02-19T10:00:00.000Z",
        "kind" => kind,
        "source" => "gateway",
        "payload" => %{}
      }
    end
  end

  defmodule FakeWS do
    def start_link(_opts) do
      {:ok,
       spawn_link(fn ->
         receive do
           _ -> :ok
         after
           5_000 -> :ok
         end
       end)}
    end

    def attach(_pid, _session_key, _after_seq), do: :ok
  end

  test "fetch_events advances cursor and deduplicates by seq" do
    config = Config.new!(base_url: "http://127.0.0.1:8080", token: "token")

    {:ok, client} =
      Session.start_link(
        owner: self(),
        config: config,
        http_module: FakeHTTP,
        ws_module: FakeWS,
        gateway_session_key: "hbs_test",
        after_seq: 0
      )

    assert {:ok, %{"next_after_seq" => 2}} = Session.fetch_events(client, 0, 50)
    assert_receive {:hivebeam_client, :event, %Event{seq: 1}}
    assert_receive {:hivebeam_client, :event, %Event{seq: 2}}

    assert {:ok, _} = Session.fetch_events(client, 2, 50)
    refute_receive {:hivebeam_client, :event, %Event{seq: 2}}, 100
    assert :sys.get_state(client).after_seq == 2
  end
end
