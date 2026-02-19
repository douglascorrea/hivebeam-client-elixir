defmodule HivebeamClient.Event do
  @moduledoc false

  alias HivebeamClient.Error

  @enforce_keys [:gateway_session_key, :seq, :ts, :kind, :source, :payload, :raw]
  defstruct [:gateway_session_key, :seq, :ts, :kind, :source, :payload, :raw]

  @type t :: %__MODULE__{
          gateway_session_key: String.t(),
          seq: pos_integer(),
          ts: String.t(),
          kind: String.t(),
          source: String.t(),
          payload: map(),
          raw: map()
        }

  @spec decode(map()) :: {:ok, t()} | {:error, Error.t()}
  def decode(raw) when is_map(raw) do
    with {:ok, gateway_session_key} <- fetch_string(raw, "gateway_session_key"),
         {:ok, seq} <- fetch_integer(raw, "seq"),
         {:ok, ts} <- fetch_string(raw, "ts"),
         {:ok, kind} <- fetch_string(raw, "kind"),
         {:ok, source} <- fetch_string(raw, "source"),
         {:ok, payload} <- fetch_map(raw, "payload") do
      {:ok,
       %__MODULE__{
         gateway_session_key: gateway_session_key,
         seq: seq,
         ts: ts,
         kind: kind,
         source: source,
         payload: payload,
         raw: raw
       }}
    end
  end

  def decode(other) do
    {:error, Error.new(:decode_error, "event payload must be map", other)}
  end

  defp fetch_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, Error.new(:decode_error, "missing field #{key}", other)}
    end
  end

  defp fetch_integer(map, key) do
    case fetch_value(map, key) do
      value when is_integer(value) -> {:ok, value}
      other -> {:error, Error.new(:decode_error, "missing integer field #{key}", other)}
    end
  end

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, Error.new(:decode_error, "missing map field #{key}", other)}
    end
  end

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {atom_key, value} when is_atom(atom_key) ->
            if Atom.to_string(atom_key) == key, do: value

          _ ->
            nil
        end)
    end
  end
end
