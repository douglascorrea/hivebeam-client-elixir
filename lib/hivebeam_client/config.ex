defmodule HivebeamClient.Config do
  @moduledoc false

  @default_base_url "http://127.0.0.1:8080"
  @default_provider "codex"
  @default_approval_mode "ask"
  @default_request_timeout_ms 30_000
  @default_ws_reconnect_ms 1_000
  @default_poll_interval_ms 500
  @default_event_page_size 200
  @default_ws_path "/v1/ws"

  @enforce_keys [:base_url, :token]
  defstruct [
    :base_url,
    :token,
    :cwd,
    provider: @default_provider,
    approval_mode: @default_approval_mode,
    request_timeout_ms: @default_request_timeout_ms,
    ws_reconnect_ms: @default_ws_reconnect_ms,
    poll_interval_ms: @default_poll_interval_ms,
    event_page_size: @default_event_page_size,
    ws_path: @default_ws_path
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t(),
          provider: String.t(),
          cwd: String.t() | nil,
          approval_mode: String.t(),
          request_timeout_ms: pos_integer(),
          ws_reconnect_ms: pos_integer(),
          poll_interval_ms: pos_integer(),
          event_page_size: pos_integer(),
          ws_path: String.t()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, HivebeamClient.Error.t()}
  def new(opts) when is_list(opts) do
    with {:ok, token} <- fetch_required_string(opts, :token, "token"),
         {:ok, base_url} <- fetch_base_url(opts),
         {:ok, ws_path} <- fetch_ws_path(opts) do
      config = %__MODULE__{
        base_url: base_url,
        token: token,
        provider: normalize_provider(Keyword.get(opts, :provider, @default_provider)),
        cwd: normalize_optional_string(Keyword.get(opts, :cwd)),
        approval_mode:
          normalize_approval_mode(Keyword.get(opts, :approval_mode, @default_approval_mode)),
        request_timeout_ms:
          normalize_pos_integer(
            Keyword.get(opts, :request_timeout_ms, @default_request_timeout_ms),
            @default_request_timeout_ms
          ),
        ws_reconnect_ms:
          normalize_pos_integer(
            Keyword.get(opts, :ws_reconnect_ms, @default_ws_reconnect_ms),
            @default_ws_reconnect_ms
          ),
        poll_interval_ms:
          normalize_pos_integer(
            Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
            @default_poll_interval_ms
          ),
        event_page_size:
          normalize_pos_integer(
            Keyword.get(opts, :event_page_size, @default_event_page_size),
            @default_event_page_size
          ),
        ws_path: ws_path
      }

      {:ok, config}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @spec ws_url(t()) :: String.t()
  def ws_url(%__MODULE__{base_url: base_url, ws_path: ws_path}) do
    uri = URI.parse(base_url)

    ws_scheme =
      case uri.scheme do
        "https" -> "wss"
        _ -> "ws"
      end

    uri
    |> Map.put(:scheme, ws_scheme)
    |> Map.put(:path, ws_path)
    |> Map.put(:query, nil)
    |> URI.to_string()
  end

  @spec merge_session_attrs(t(), map()) :: map()
  def merge_session_attrs(%__MODULE__{} = config, attrs) when is_map(attrs) do
    attrs
    |> Map.put_new("provider", config.provider)
    |> maybe_put_new("cwd", config.cwd)
    |> Map.put_new("approval_mode", config.approval_mode)
  end

  defp fetch_base_url(opts) do
    value = Keyword.get(opts, :base_url, @default_base_url)

    case normalize_optional_string(value) do
      nil ->
        {:ok, @default_base_url}

      base_url ->
        uri = URI.parse(base_url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
          {:ok, String.trim_trailing(base_url, "/")}
        else
          {:error, HivebeamClient.Error.new(:invalid_config, "base_url must be http(s) URL")}
        end
    end
  end

  defp fetch_ws_path(opts) do
    case normalize_optional_string(Keyword.get(opts, :ws_path, @default_ws_path)) do
      nil ->
        {:ok, @default_ws_path}

      "/" <> _ = path ->
        {:ok, path}

      _ ->
        {:error, HivebeamClient.Error.new(:invalid_config, "ws_path must start with /")}
    end
  end

  defp fetch_required_string(opts, key, label) do
    case normalize_optional_string(Keyword.get(opts, key)) do
      nil -> {:error, HivebeamClient.Error.new(:invalid_config, "#{label} is required")}
      value -> {:ok, value}
    end
  end

  defp normalize_provider(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> @default_provider
      provider -> provider
    end
  end

  defp normalize_approval_mode(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "allow" -> "allow"
      "deny" -> "deny"
      _ -> "ask"
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_pos_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_pos_integer(_value, default), do: default

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
end
