defmodule HivebeamClient.Transport.WS do
  @moduledoc false
  use WebSockex

  alias HivebeamClient.Config

  @type state :: %{
          owner: pid(),
          config: Config.t(),
          session_key: String.t() | nil,
          after_seq: integer(),
          reconnect_ms: pos_integer()
        }

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    owner = Keyword.fetch!(opts, :owner)
    session_key = Keyword.get(opts, :session_key)
    after_seq = Keyword.get(opts, :after_seq, 0)
    ws_url = Keyword.get(opts, :ws_url, Config.ws_url(config))

    state = %{
      owner: owner,
      config: config,
      session_key: session_key,
      after_seq: after_seq,
      reconnect_ms: config.ws_reconnect_ms
    }

    headers = [{"authorization", "Bearer #{config.token}"}]
    WebSockex.start_link(ws_url, __MODULE__, state, extra_headers: headers)
  end

  @spec attach(pid(), String.t(), integer()) :: :ok
  def attach(pid, gateway_session_key, after_seq \\ 0)
      when is_pid(pid) and is_binary(gateway_session_key) and is_integer(after_seq) do
    WebSockex.cast(pid, {:attach, gateway_session_key, after_seq})
  end

  @spec prompt(pid(), String.t(), String.t(), pos_integer() | nil) :: :ok
  def prompt(pid, request_id, text, timeout_ms \\ nil)
      when is_pid(pid) and is_binary(request_id) and is_binary(text) do
    WebSockex.cast(pid, {:prompt, request_id, text, timeout_ms})
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid), do: WebSockex.cast(pid, :cancel)

  @spec approve(pid(), String.t(), String.t()) :: :ok
  def approve(pid, approval_ref, decision)
      when is_pid(pid) and is_binary(approval_ref) and is_binary(decision) do
    WebSockex.cast(pid, {:approval, approval_ref, decision})
  end

  @spec ping(pid()) :: :ok
  def ping(pid) when is_pid(pid), do: WebSockex.cast(pid, :ping)

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:hivebeam_ws, :connected, %{transport: :ws}})

    case state.session_key do
      key when is_binary(key) and key != "" ->
        frame = attach_frame(key, state.after_seq)
        {:reply, {:text, encode(frame)}, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(disconnect, state) do
    send(state.owner, {:hivebeam_ws, :disconnected, disconnect})
    Process.sleep(state.reconnect_ms)
    {:reconnect, state}
  end

  @impl true
  def handle_cast({:attach, gateway_session_key, after_seq}, state) do
    frame = attach_frame(gateway_session_key, after_seq)

    {:reply, {:text, encode(frame)},
     %{state | session_key: gateway_session_key, after_seq: after_seq}}
  end

  def handle_cast({:prompt, request_id, text, timeout_ms}, state) do
    payload =
      %{
        "type" => "prompt",
        "request_id" => request_id,
        "text" => text
      }
      |> maybe_put_timeout(timeout_ms)

    {:reply, {:text, encode(payload)}, state}
  end

  def handle_cast(:cancel, state) do
    {:reply, {:text, encode(%{"type" => "cancel"})}, state}
  end

  def handle_cast({:approval, approval_ref, decision}, state) do
    frame = %{"type" => "approval", "approval_ref" => approval_ref, "decision" => decision}
    {:reply, {:text, encode(frame)}, state}
  end

  def handle_cast(:ping, state) do
    {:reply, {:text, encode(%{"type" => "ping"})}, state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "attached"} = frame} ->
        send(state.owner, {:hivebeam_ws, :attached, frame})
        next_after_seq = frame["next_after_seq"] || state.after_seq
        {:ok, %{state | after_seq: normalize_after_seq(next_after_seq, state.after_seq)}}

      {:ok, %{"type" => "event", "data" => event} = frame} when is_map(event) ->
        send(state.owner, {:hivebeam_ws, :event, event})
        send(state.owner, {:hivebeam_ws, :frame, frame})
        next_after_seq = normalize_after_seq(event["seq"], state.after_seq)
        {:ok, %{state | after_seq: next_after_seq}}

      {:ok, frame} when is_map(frame) ->
        send(state.owner, {:hivebeam_ws, :frame, frame})
        {:ok, state}

      {:error, reason} ->
        send(state.owner, {:hivebeam_ws, :decode_error, reason})
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  defp attach_frame(gateway_session_key, after_seq) do
    %{
      "type" => "attach",
      "gateway_session_key" => gateway_session_key,
      "after_seq" => max(after_seq, 0)
    }
  end

  defp maybe_put_timeout(payload, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Map.put(payload, "timeout_ms", timeout_ms)
  end

  defp maybe_put_timeout(payload, _timeout_ms), do: payload

  defp normalize_after_seq(value, fallback) when is_integer(value), do: max(value, fallback)
  defp normalize_after_seq(_value, fallback), do: fallback

  defp encode(payload), do: Jason.encode!(payload)
end
