defmodule HivebeamClient.TestSupport.GatewayHarness do
  @moduledoc false
  use GenServer

  @max_log_bytes 40_000

  @type info :: %{
          base_url: String.t(),
          token: String.t(),
          port: pos_integer(),
          gateway_repo: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec info(pid()) :: info()
  def info(pid), do: GenServer.call(pid, :info)

  @spec logs(pid()) :: String.t()
  def logs(pid), do: GenServer.call(pid, :logs)

  @impl true
  def init(opts) do
    gateway_repo = resolve_gateway_repo(opts)
    fake_acp = resolve_fake_acp_path(opts)
    token = Keyword.get(opts, :token, "sdk-test-token")
    port = free_port()
    bind = "127.0.0.1:#{port}"

    data_dir =
      Path.join(System.tmp_dir!(), "hivebeam_sdk_it_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)

    env_prefix =
      [
        "MIX_ENV=test",
        "HIVEBEAM_GATEWAY_TOKEN=#{shq(token)}",
        "HIVEBEAM_GATEWAY_BIND=#{shq(bind)}",
        "HIVEBEAM_GATEWAY_DATA_DIR=#{shq(data_dir)}",
        "HIVEBEAM_CODEX_ACP_CMD=#{shq(fake_acp)}",
        "HIVEBEAM_CLAUDE_AGENT_ACP_CMD=#{shq(fake_acp)}"
      ]
      |> Enum.join(" ")

    command = "cd #{shq(gateway_repo)} && #{env_prefix} mix run --no-halt"

    shell = System.find_executable("sh") || "/bin/sh"

    port_handle =
      Port.open(
        {:spawn_executable, shell},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: ["-lc", command]
        ]
      )

    state = %{
      gateway_repo: gateway_repo,
      fake_acp: fake_acp,
      token: token,
      port: port,
      base_url: "http://127.0.0.1:#{port}",
      data_dir: data_dir,
      port_handle: port_handle,
      log_buffer: ""
    }

    case wait_until_healthy(state.base_url) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        safe_close_port(port_handle)
        File.rm_rf!(data_dir)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       base_url: state.base_url,
       token: state.token,
       port: state.port,
       gateway_repo: state.gateway_repo
     }, state}
  end

  def handle_call(:logs, _from, state) do
    {:reply, state.log_buffer, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port_handle: port} = state) when is_binary(chunk) do
    merged = trim_log_buffer(state.log_buffer <> chunk)
    {:noreply, %{state | log_buffer: merged}}
  end

  def handle_info({port, {:exit_status, status}}, %{port_handle: port} = state) do
    {:stop, {:gateway_exited, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    safe_close_port(state.port_handle)
    File.rm_rf(state.data_dir)
    :ok
  rescue
    _ -> :ok
  end

  defp wait_until_healthy(base_url, attempts \\ 2_400)

  defp wait_until_healthy(_base_url, 0), do: {:error, :gateway_boot_timeout}

  defp wait_until_healthy(base_url, attempts) do
    case Req.get(base_url <> "/healthz", retry: false, receive_timeout: 200) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_until_healthy(base_url, attempts - 1)
    end
  end

  defp resolve_gateway_repo(opts) do
    value =
      Keyword.get(opts, :gateway_repo) ||
        System.get_env("HIVEBEAM_GATEWAY_REPO") ||
        Path.expand("../hivebeam", File.cwd!())

    expanded = Path.expand(value)

    if File.dir?(expanded) do
      expanded
    else
      raise "gateway repo not found: #{expanded}"
    end
  end

  defp resolve_fake_acp_path(opts) do
    value =
      Keyword.get(opts, :fake_acp) ||
        Path.expand("fake_acp", Path.dirname(__ENV__.file))

    if File.exists?(value) do
      value
    else
      raise "fake ACP command not found: #{value}"
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp trim_log_buffer(buffer) when byte_size(buffer) <= @max_log_bytes, do: buffer

  defp trim_log_buffer(buffer),
    do: binary_part(buffer, byte_size(buffer) - @max_log_bytes, @max_log_bytes)

  defp safe_close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  defp safe_close_port(_port), do: :ok

  defp shq(value) do
    escaped = value |> to_string() |> String.replace("'", "'\"'\"'")
    "'#{escaped}'"
  end
end
