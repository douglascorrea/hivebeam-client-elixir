defmodule HivebeamClient.Integration.SessionIntegrationTest do
  use ExUnit.Case, async: false

  alias HivebeamClient.Event
  alias HivebeamClient.TestSupport.GatewayHarness

  @moduletag :integration

  setup_all do
    gateway_repo =
      System.get_env("HIVEBEAM_GATEWAY_REPO") ||
        Path.expand("../../../../hivebeam", __DIR__)

    {:ok, harness} = GatewayHarness.start_link(gateway_repo: gateway_repo)
    info = GatewayHarness.info(harness)

    on_exit(fn ->
      Process.exit(harness, :normal)
    end)

    {:ok, %{harness: harness, gateway: info}}
  end

  test "full lifecycle works for codex and claude providers", %{gateway: gateway} do
    Enum.each(["codex", "claude"], fn provider ->
      {:ok, client} =
        HivebeamClient.start_link(
          base_url: gateway.base_url,
          token: gateway.token,
          provider: provider,
          ws_reconnect_ms: 150,
          poll_interval_ms: 100
        )

      {:ok, session} = HivebeamClient.create_session(client, %{"provider" => provider})
      assert session["provider"] == provider

      session_key = session["gateway_session_key"]
      assert is_binary(session_key)

      {:ok, _attach_payload} = HivebeamClient.attach(client, session_key)
      {:ok, _prompt_payload} = HivebeamClient.prompt(client, "req-#{provider}-1", "hello gateway")

      assert %Event{kind: "stream_update"} = wait_for_event("stream_update", 20_000)
      assert %Event{kind: "prompt_completed"} = wait_for_event("prompt_completed", 20_000)

      assert {:ok, %{"closed" => true}} = HivebeamClient.close(client)
    end)
  end

  test "attach replay returns events after cursor", %{gateway: gateway} do
    {:ok, producer} =
      HivebeamClient.start_link(
        base_url: gateway.base_url,
        token: gateway.token,
        provider: "codex"
      )

    {:ok, session} = HivebeamClient.create_session(producer, %{"provider" => "codex"})
    session_key = session["gateway_session_key"]

    {:ok, _} = HivebeamClient.attach(producer, session_key)
    {:ok, _} = HivebeamClient.prompt(producer, "req-replay-1", "replay test")
    assert %Event{kind: "prompt_completed"} = wait_for_event("prompt_completed", 20_000)

    {:ok, page} = HivebeamClient.fetch_events(producer, 0, 200)
    events = page["events"]
    assert length(events) > 1

    cutoff_seq =
      events
      |> Enum.at(max(length(events) - 2, 0))
      |> Map.fetch!("seq")

    {:ok, consumer} =
      HivebeamClient.start_link(
        base_url: gateway.base_url,
        token: gateway.token,
        provider: "codex"
      )

    {:ok, replay_payload} =
      HivebeamClient.attach(
        consumer,
        gateway_session_key: session_key,
        after_seq: cutoff_seq,
        limit: 200
      )

    replay_events = replay_payload["events"]
    assert replay_events != []
    assert Enum.all?(replay_events, &(&1["seq"] > cutoff_seq))
    assert Enum.any?(replay_events, &(&1["kind"] == "prompt_completed"))
  end

  test "approval loop resolves and prompt finishes", %{gateway: gateway} do
    {:ok, client} =
      HivebeamClient.start_link(
        base_url: gateway.base_url,
        token: gateway.token,
        provider: "codex"
      )

    {:ok, session} = HivebeamClient.create_session(client, %{"provider" => "codex"})
    session_key = session["gateway_session_key"]
    {:ok, _} = HivebeamClient.attach(client, session_key)

    {:ok, _} =
      HivebeamClient.prompt(
        client,
        "req-approval-1",
        "please run action that requires approval",
        timeout_ms: 60_000
      )

    approval_event = wait_for_event("approval_requested", 20_000)
    approval_ref = approval_event.payload["approval_ref"]
    assert is_binary(approval_ref)

    assert {:ok, %{"accepted" => true}} = HivebeamClient.approve(client, approval_ref, "allow")
    assert %Event{kind: "approval_resolved"} = wait_for_event("approval_resolved", 20_000)
    assert %Event{kind: "prompt_completed"} = wait_for_event("prompt_completed", 20_000)
  end

  test "cancel endpoint is reachable through sdk", %{gateway: gateway} do
    {:ok, client} =
      HivebeamClient.start_link(
        base_url: gateway.base_url,
        token: gateway.token,
        provider: "codex"
      )

    {:ok, session} = HivebeamClient.create_session(client, %{"provider" => "codex"})
    session_key = session["gateway_session_key"]
    {:ok, _} = HivebeamClient.attach(client, session_key)

    assert {:ok, payload} = HivebeamClient.cancel(client)
    assert is_boolean(payload["accepted"])
  end

  test "ws reconnect resumes cursor and polling covers downtime", %{gateway: gateway} do
    {:ok, client} =
      HivebeamClient.start_link(
        base_url: gateway.base_url,
        token: gateway.token,
        provider: "codex",
        ws_reconnect_ms: 1_000,
        poll_interval_ms: 100
      )

    {:ok, session} = HivebeamClient.create_session(client, %{"provider" => "codex"})
    session_key = session["gateway_session_key"]
    {:ok, _} = HivebeamClient.attach(client, session_key)

    {:ok, _} = HivebeamClient.prompt(client, "req-reconnect-1", "first prompt")
    assert %Event{kind: "prompt_completed"} = wait_for_event("prompt_completed", 20_000)

    state_before_drop = :sys.get_state(client)
    previous_seq = state_before_drop.after_seq
    Process.exit(state_before_drop.ws_pid, :kill)

    _ = wait_for_connection_status(:disconnected, 10_000)

    {:ok, _} = HivebeamClient.prompt(client, "req-reconnect-2", "second prompt after ws drop")

    completed_after_drop = wait_for_event("prompt_completed", 20_000)
    assert completed_after_drop.seq > previous_seq

    _ = wait_for_connection_status(:connected, 20_000)
  end

  defp wait_for_event(kind, timeout) when is_binary(kind) and is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_kind(kind, deadline)
  end

  defp do_wait_for_kind(kind, deadline_ms) do
    now_ms = System.monotonic_time(:millisecond)
    remaining = max(deadline_ms - now_ms, 0)

    receive do
      {:hivebeam_client, :event, %Event{kind: ^kind} = event} ->
        event

      {:hivebeam_client, :event, %Event{}} ->
        do_wait_for_kind(kind, deadline_ms)
    after
      remaining ->
        flunk("timed out waiting for event kind=#{kind}")
    end
  end

  defp wait_for_connection_status(status, timeout)
       when status in [:connected, :disconnected] and is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_connection_status(status, deadline)
  end

  defp do_wait_for_connection_status(status, deadline_ms) do
    now_ms = System.monotonic_time(:millisecond)
    remaining = max(deadline_ms - now_ms, 0)

    receive do
      {:hivebeam_client, ^status, payload} ->
        payload

      _other ->
        do_wait_for_connection_status(status, deadline_ms)
    after
      remaining ->
        flunk("timed out waiting for connection status=#{status}")
    end
  end
end
