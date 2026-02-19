defmodule HivebeamClient.Session do
  @moduledoc false
  use GenServer

  alias HivebeamClient.Config
  alias HivebeamClient.Error
  alias HivebeamClient.Event
  alias HivebeamClient.Transport.HTTP
  alias HivebeamClient.Transport.WS

  @type state :: %{
          owner: pid(),
          config: Config.t(),
          http_module: module(),
          ws_module: module(),
          ws_pid: pid() | nil,
          ws_monitor_ref: reference() | nil,
          ws_connected?: boolean(),
          ws_restart_timer_ref: reference() | nil,
          poll_timer_ref: reference() | nil,
          gateway_session_key: String.t() | nil,
          after_seq: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec create_session(GenServer.server(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create_session(server, attrs \\ %{}) when is_map(attrs) do
    GenServer.call(server, {:create_session, attrs})
  end

  @spec attach(GenServer.server(), String.t() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def attach(server, arg), do: GenServer.call(server, {:attach, arg})

  @spec prompt(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prompt(server, request_id, text, opts \\ [])
      when is_binary(request_id) and is_binary(text) and is_list(opts) do
    GenServer.call(server, {:prompt, request_id, text, opts})
  end

  @spec cancel(GenServer.server(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(server, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:cancel, opts})
  end

  @spec approve(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def approve(server, approval_ref, decision, opts \\ [])
      when is_binary(approval_ref) and is_binary(decision) and is_list(opts) do
    GenServer.call(server, {:approve, approval_ref, decision, opts})
  end

  @spec close(GenServer.server(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def close(server, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:close, opts})
  end

  @spec fetch_events(GenServer.server(), integer(), pos_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def fetch_events(server, after_seq, limit)
      when is_integer(after_seq) and is_integer(limit) and limit > 0 do
    GenServer.call(server, {:fetch_events, after_seq, limit})
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    config = normalize_config(opts)

    state = %{
      owner: owner,
      config: config,
      http_module: Keyword.get(opts, :http_module, HTTP),
      ws_module: Keyword.get(opts, :ws_module, WS),
      ws_pid: nil,
      ws_monitor_ref: nil,
      ws_connected?: false,
      ws_restart_timer_ref: nil,
      poll_timer_ref: nil,
      gateway_session_key: Keyword.get(opts, :gateway_session_key),
      after_seq: max(Keyword.get(opts, :after_seq, 0), 0)
    }

    {:ok, state, {:continue, :start_ws}}
  end

  @impl true
  def handle_continue(:start_ws, state) do
    {:noreply, maybe_start_ws(state)}
  end

  @impl true
  def handle_call({:create_session, attrs}, _from, state) do
    attrs = Config.merge_session_attrs(state.config, attrs)

    case state.http_module.create_session(state.config, attrs) do
      {:ok, session} when is_map(session) ->
        session_key = session["gateway_session_key"] || session[:gateway_session_key]

        next_after_seq =
          normalize_after_seq(session["last_seq"] || session[:last_seq], state.after_seq)

        next_state =
          state
          |> Map.put(:gateway_session_key, session_key || state.gateway_session_key)
          |> Map.put(:after_seq, next_after_seq)
          |> ensure_ws_attached()

        {:reply, {:ok, session}, next_state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:attach, arg}, _from, state) do
    with {:ok, session_key, after_seq, limit} <- normalize_attach_args(state, arg),
         {:ok, payload} <- state.http_module.attach(state.config, session_key, after_seq, limit) do
      events = payload["events"] || payload[:events] || []

      next_after_seq =
        normalize_after_seq(payload["next_after_seq"] || payload[:next_after_seq], after_seq)

      next_state =
        state
        |> Map.put(:gateway_session_key, session_key)
        |> Map.put(:after_seq, max(state.after_seq, next_after_seq))
        |> ingest_events(events)
        |> ensure_ws_attached()

      {:reply, {:ok, payload}, next_state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:prompt, request_id, text, opts}, _from, state) do
    with {:ok, session_key} <- require_session_key(state),
         {:ok, payload} <-
           state.http_module.prompt(
             state.config,
             session_key,
             request_id,
             text,
             normalize_timeout(Keyword.get(opts, :timeout_ms))
           ) do
      {:reply, {:ok, payload}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel, _opts}, _from, state) do
    with {:ok, session_key} <- require_session_key(state),
         {:ok, payload} <- state.http_module.cancel(state.config, session_key) do
      {:reply, {:ok, payload}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:approve, approval_ref, decision, _opts}, _from, state) do
    with {:ok, session_key} <- require_session_key(state),
         {:ok, payload} <-
           state.http_module.approve(state.config, session_key, approval_ref, decision) do
      {:reply, {:ok, payload}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close, _opts}, _from, state) do
    with {:ok, session_key} <- require_session_key(state),
         {:ok, payload} <- state.http_module.close(state.config, session_key) do
      next_state =
        state
        |> cancel_poll_timer()
        |> stop_ws()
        |> Map.put(:gateway_session_key, nil)

      {:reply, {:ok, payload}, next_state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:fetch_events, after_seq, limit}, _from, state) do
    with {:ok, session_key} <- require_session_key(state),
         {:ok, payload} <-
           state.http_module.fetch_events(state.config, session_key, after_seq, limit) do
      events = payload["events"] || payload[:events] || []

      next_after_seq =
        normalize_after_seq(payload["next_after_seq"] || payload[:next_after_seq], after_seq)

      next_state =
        state
        |> ingest_events(events)
        |> Map.put(:after_seq, max(state.after_seq, next_after_seq))

      {:reply, {:ok, payload}, next_state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({:hivebeam_ws, :connected, meta}, state) do
    send(state.owner, {:hivebeam_client, :connected, meta})

    next_state =
      state
      |> Map.put(:ws_connected?, true)
      |> cancel_poll_timer()
      |> cancel_ws_restart_timer()
      |> maybe_ws_attach()

    {:noreply, next_state}
  end

  def handle_info({:hivebeam_ws, :disconnected, reason}, state) do
    send(state.owner, {:hivebeam_client, :disconnected, reason})
    {:noreply, state |> Map.put(:ws_connected?, false) |> ensure_polling()}
  end

  def handle_info({:hivebeam_ws, :attached, frame}, state) do
    next_after_seq = normalize_after_seq(frame["next_after_seq"], state.after_seq)
    {:noreply, %{state | after_seq: max(state.after_seq, next_after_seq)}}
  end

  def handle_info({:hivebeam_ws, :event, raw_event}, state) do
    {:noreply, ingest_events(state, [raw_event])}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{ws_monitor_ref: ref, ws_pid: pid} = state
      ) do
    send(state.owner, {:hivebeam_client, :disconnected, reason})

    next_state =
      state
      |> Map.put(:ws_pid, nil)
      |> Map.put(:ws_monitor_ref, nil)
      |> Map.put(:ws_connected?, false)
      |> schedule_ws_restart()
      |> ensure_polling()

    {:noreply, next_state}
  end

  def handle_info(:restart_ws, state) do
    next_state =
      state
      |> Map.put(:ws_restart_timer_ref, nil)
      |> maybe_start_ws()

    {:noreply, next_state}
  end

  def handle_info(:poll_events, state) do
    state = %{state | poll_timer_ref: nil}

    next_state =
      cond do
        state.ws_connected? ->
          state

        not is_binary(state.gateway_session_key) ->
          state

        true ->
          case state.http_module.fetch_events(
                 state.config,
                 state.gateway_session_key,
                 state.after_seq,
                 state.config.event_page_size
               ) do
            {:ok, payload} ->
              events = payload["events"] || payload[:events] || []

              next_after_seq =
                normalize_after_seq(
                  payload["next_after_seq"] || payload[:next_after_seq],
                  state.after_seq
                )

              state
              |> ingest_events(events)
              |> Map.put(:after_seq, max(state.after_seq, next_after_seq))

            {:error, _error} ->
              state
          end
      end

    {:noreply, ensure_polling(next_state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp normalize_config(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        config

      nil ->
        Config.new!(opts)

      _ ->
        raise Error.new(:invalid_config, "config must be %HivebeamClient.Config{}")
    end
  end

  defp normalize_attach_args(state, gateway_session_key) when is_binary(gateway_session_key) do
    {:ok, gateway_session_key, state.after_seq, state.config.event_page_size}
  end

  defp normalize_attach_args(state, opts) when is_list(opts) do
    session_key = Keyword.get(opts, :gateway_session_key, state.gateway_session_key)

    after_seq =
      normalize_after_seq(Keyword.get(opts, :after_seq, state.after_seq), state.after_seq)

    limit =
      normalize_limit(
        Keyword.get(opts, :limit, state.config.event_page_size),
        state.config.event_page_size
      )

    if is_binary(session_key) and session_key != "" do
      {:ok, session_key, after_seq, limit}
    else
      {:error, Error.new(:session_not_attached, "gateway_session_key is required")}
    end
  end

  defp normalize_attach_args(_state, _arg) do
    {:error, Error.new(:invalid_request, "attach expects gateway session key or keyword list")}
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: nil

  defp normalize_limit(value, _fallback) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value, fallback), do: fallback

  defp normalize_after_seq(value, fallback) when is_integer(value), do: max(value, fallback)
  defp normalize_after_seq(_value, fallback), do: fallback

  defp require_session_key(%{gateway_session_key: gateway_session_key})
       when is_binary(gateway_session_key) and gateway_session_key != "" do
    {:ok, gateway_session_key}
  end

  defp require_session_key(_state) do
    {:error, Error.new(:session_not_attached, "session is not attached")}
  end

  defp ingest_events(state, events) when is_list(events) do
    Enum.reduce(events, state, fn raw_event, acc ->
      case Event.decode(raw_event) do
        {:ok, event} ->
          if event.seq > acc.after_seq do
            send(acc.owner, {:hivebeam_client, :event, event})
            %{acc | after_seq: event.seq}
          else
            acc
          end

        {:error, _error} ->
          acc
      end
    end)
  end

  defp ingest_events(state, _events), do: state

  defp maybe_start_ws(%{ws_pid: pid} = state) when is_pid(pid), do: state

  defp maybe_start_ws(state) do
    case state.ws_module.start_link(
           config: state.config,
           owner: self(),
           session_key: state.gateway_session_key,
           after_seq: state.after_seq
         ) do
      {:ok, ws_pid} ->
        Process.unlink(ws_pid)
        %{state | ws_pid: ws_pid, ws_monitor_ref: Process.monitor(ws_pid)}

      {:error, _reason} ->
        state |> Map.put(:ws_connected?, false) |> schedule_ws_restart() |> ensure_polling()
    end
  end

  defp ensure_ws_attached(state) do
    state
    |> maybe_start_ws()
    |> maybe_ws_attach()
  end

  defp maybe_ws_attach(%{ws_pid: ws_pid, gateway_session_key: gateway_session_key} = state)
       when is_pid(ws_pid) and is_binary(gateway_session_key) and gateway_session_key != "" do
    state.ws_module.attach(ws_pid, gateway_session_key, state.after_seq)
    state
  end

  defp maybe_ws_attach(state), do: state

  defp ensure_polling(%{ws_connected?: true} = state), do: cancel_poll_timer(state)
  defp ensure_polling(%{poll_timer_ref: ref} = state) when is_reference(ref), do: state

  defp ensure_polling(%{gateway_session_key: gateway_session_key} = state)
       when is_binary(gateway_session_key) do
    ref = Process.send_after(self(), :poll_events, state.config.poll_interval_ms)
    %{state | poll_timer_ref: ref}
  end

  defp ensure_polling(state), do: state

  defp cancel_poll_timer(%{poll_timer_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | poll_timer_ref: nil}
  end

  defp cancel_poll_timer(state), do: state

  defp schedule_ws_restart(%{ws_restart_timer_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_ws_restart(state) do
    ref = Process.send_after(self(), :restart_ws, state.config.ws_reconnect_ms)
    %{state | ws_restart_timer_ref: ref}
  end

  defp cancel_ws_restart_timer(%{ws_restart_timer_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | ws_restart_timer_ref: nil}
  end

  defp cancel_ws_restart_timer(state), do: state

  defp stop_ws(%{ws_pid: pid, ws_monitor_ref: ref} = state)
       when is_pid(pid) and is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :normal)

    state
    |> Map.put(:ws_pid, nil)
    |> Map.put(:ws_monitor_ref, nil)
    |> Map.put(:ws_connected?, false)
  end

  defp stop_ws(state), do: state
end
