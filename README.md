# hivebeam-client-elixir

Elixir SDK for Hivebeam gateway `/v1` contracts.

The SDK is transport-unified:
- HTTP control plane for session lifecycle operations.
- WebSocket realtime stream with auto attach/reconnect.
- Cursor-aware polling fallback while WS is unavailable.

## Status

- Distribution target for this phase: git/path dependency.
- Contract major pinned: `/v1` (see `COMPATIBILITY.md`).

## Usage

```elixir
{:ok, client} =
  HivebeamClient.start_link(
    base_url: "http://127.0.0.1:8080",
    token: "dev-token",
    provider: "codex"
  )

{:ok, session} =
  HivebeamClient.create_session(client, %{
    "provider" => "codex",
    "cwd" => File.cwd!(),
    "approval_mode" => "ask"
  })

session_key = session["gateway_session_key"]

{:ok, _} = HivebeamClient.attach(client, session_key)
{:ok, _} = HivebeamClient.prompt(client, "req-1", "hello", timeout_ms: 30_000)
```

## Event forwarding

The SDK forwards runtime messages to the owner process:

- `{:hivebeam_client, :event, %HivebeamClient.Event{...}}`
- `{:hivebeam_client, :connected, meta}`
- `{:hivebeam_client, :disconnected, reason}`

## Public API

- `start_link/1`
- `create_session/2`
- `attach/2`
- `prompt/4`
- `cancel/2`
- `approve/4`
- `close/2`
- `fetch_events/3`

## Contracts

Pinned gateway contract snapshot lives in `contracts/`.
