# Hivebeam Elixir SDK Agent Notes

This repository is the Elixir client SDK for Hivebeam gateway `/v1` contracts.

## Core commands

- Install deps: `mix deps.get`
- Compile: `mix compile`
- Run tests: `mix test`
- Format check: `mix format --check-formatted`
- Compile strict: `mix compile --warnings-as-errors`

## Editing expectations

- Keep SDK behavior aligned with `hivebeam/api/v1/*` contracts.
- Prefer compatibility-safe changes for existing public functions:
  - `create_session/2`
  - `attach/2`
  - `prompt/4`
  - `cancel/2`
  - `approve/4`
  - `close/2`
  - `fetch_events/3`
- Maintain transport behavior:
  - HTTP lifecycle/control
  - WebSocket realtime stream
  - polling fallback

## Verification

When changing transport/session logic, run:

- `mix test test/hivebeam_client/session_test.exs`
- `mix test test/hivebeam_client/integration/session_integration_test.exs`
- `mix compile --warnings-as-errors`
