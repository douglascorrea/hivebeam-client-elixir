defmodule HivebeamClient.Transport.HTTP do
  @moduledoc false

  alias HivebeamClient.Config
  alias HivebeamClient.Error

  @spec create_session(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create_session(config, attrs) when is_map(attrs) do
    request(config, :post, "/v1/sessions", json: attrs)
  end

  @spec get_session(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_session(config, gateway_session_key) when is_binary(gateway_session_key) do
    request(config, :get, "/v1/sessions/#{gateway_session_key}")
  end

  @spec attach(Config.t(), String.t(), integer(), pos_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def attach(config, gateway_session_key, after_seq, limit)
      when is_binary(gateway_session_key) and is_integer(after_seq) and is_integer(limit) and
             limit > 0 do
    body = %{"after_seq" => after_seq, "limit" => limit}
    request(config, :post, "/v1/sessions/#{gateway_session_key}/attach", json: body)
  end

  @spec prompt(Config.t(), String.t(), String.t(), String.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def prompt(config, gateway_session_key, request_id, text, timeout_ms)
      when is_binary(gateway_session_key) and is_binary(request_id) and is_binary(text) do
    body =
      %{
        "request_id" => request_id,
        "text" => text
      }
      |> maybe_put_timeout(timeout_ms)

    request(config, :post, "/v1/sessions/#{gateway_session_key}/prompts", json: body)
  end

  @spec cancel(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(config, gateway_session_key) when is_binary(gateway_session_key) do
    request(config, :post, "/v1/sessions/#{gateway_session_key}/cancel")
  end

  @spec approve(Config.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def approve(config, gateway_session_key, approval_ref, decision)
      when is_binary(gateway_session_key) and is_binary(approval_ref) and is_binary(decision) do
    body = %{"approval_ref" => approval_ref, "decision" => decision}
    request(config, :post, "/v1/sessions/#{gateway_session_key}/approvals", json: body)
  end

  @spec close(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def close(config, gateway_session_key) when is_binary(gateway_session_key) do
    request(config, :delete, "/v1/sessions/#{gateway_session_key}")
  end

  @spec fetch_events(Config.t(), String.t(), integer(), pos_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def fetch_events(config, gateway_session_key, after_seq, limit)
      when is_binary(gateway_session_key) and is_integer(after_seq) and is_integer(limit) and
             limit > 0 do
    query = [after_seq: after_seq, limit: limit]
    request(config, :get, "/v1/sessions/#{gateway_session_key}/events", params: query)
  end

  defp request(config, method, path, opts \\ []) do
    request_opts =
      [
        method: method,
        url: config.base_url <> path,
        headers: [{"authorization", "Bearer #{config.token}"}],
        receive_timeout: config.request_timeout_ms,
        retry: false
      ]
      |> maybe_put_json(opts)
      |> maybe_put_params(opts)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.from_http(status, normalize_body(body))}

      {:error, reason} ->
        {:error, Error.from_transport(reason)}
    end
  end

  defp maybe_put_json(opts, request_opts) do
    case Keyword.fetch(request_opts, :json) do
      {:ok, payload} -> Keyword.put(opts, :json, payload)
      :error -> opts
    end
  end

  defp maybe_put_params(opts, request_opts) do
    case Keyword.fetch(request_opts, :params) do
      {:ok, params} -> Keyword.put(opts, :params, params)
      :error -> opts
    end
  end

  defp maybe_put_timeout(map, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Map.put(map, "timeout_ms", timeout_ms)
  end

  defp maybe_put_timeout(map, _timeout_ms), do: map

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp normalize_body(body), do: body
end
