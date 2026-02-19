# Compatibility Matrix

`hivebeam-client-elixir` tracks gateway wire contracts published from `hivebeam/api/v1`.

## SDK to Contract

| SDK version | Gateway contract major | Contract snapshot path |
| --- | --- | --- |
| `0.1.x` | `/v1` | `contracts/` |

## Policy

- SDK minor/patch releases stay compatible with the same gateway major contract (`/v1`).
- Any breaking gateway protocol change requires a new gateway major namespace (`/v2`) and a new SDK major.
- Contract files pinned under `contracts/` are the CI source of truth for this SDK.
