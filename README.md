# agentmemory-railway

Wrapper image for deploying [agentmemory](https://github.com/rohitg00/agentmemory) —
persistent memory for AI coding agents (Claude Code, Codex CLI, Cursor, Cline, Goose)
over REST and MCP — as a single Railway service on one volume.

Published as `ghcr.io/bon5co/agentmemory-railway:latest`.

## What this image adds over the upstream package

Upstream ships `deploy/railway/{Dockerfile,entrypoint.sh}`, which this image is derived
from. The differences are all Railway-specific:

| Concern | Upstream deploy recipe | Here |
|---|---|---|
| Build | deployer builds from source on every deploy | prebuilt, pinned image |
| Secret | generated on first boot, printed once into the deploy log | supplied by the environment (`${{secret(32)}}`), never logged |
| Empty secret | auth silently disabled (`if (!secret) return null`) | container refuses to boot |
| API bind | `0.0.0.0:3111` | `127.0.0.1:3111`, reachable only through the in-container gateway |
| Viewer | loopback only, so unreachable on a hosted deploy | published on the same port behind basic auth |
| Port | app listens on a fixed port | nginx gateway listens on Railway's injected `$PORT` |

## Why the viewer needs its own gate

`startViewerServer()` only demands inbound credentials when it is bound to a non-loopback
address. Bound to loopback — the default, and the only mode that works behind a gateway —
it proxies to the REST API **injecting `AGENTMEMORY_SECRET` itself**, so it authenticates
nobody. Publishing it raw would hand every caller full memory read/write without a token.
The gateway therefore serves it behind HTTP basic auth (`admin` / `AGENTMEMORY_SECRET`,
username overridable with `AGENTMEMORY_VIEWER_USER`).

## Why iii-sdk is pinned through `overrides`

agentmemory registers as a worker against the `iii` engine, and the two versions have to
match. `npm install -g` ignores the `overrides` field, so a global install resolves
agentmemory's `iii-sdk` range up to 0.11.6 — the release that moved to the sandboxed
worker model agentmemory has not been refactored for — against an 0.11.2 engine. The
install happens in a local prefix with an explicit override, and the build asserts the
resolved versions before the image is published.

## Layout

- `Dockerfile` — pins agentmemory, the `iii` engine and `iii-sdk`; installs nginx.
- `railway-entrypoint.sh` — secret guard, volume ownership repair, engine config with
  absolute `/data` paths, gateway config, drops to `node` via `gosu`.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `AGENTMEMORY_SECRET` | yes | Bearer token for REST + MCP, and the viewer's basic-auth password. |
| `PORT` | injected | Gateway listen port. |
| `AGENTMEMORY_DATA_DIR` | no | Volume mount path, default `/data`. |
| `AGENTMEMORY_VIEWER_USER` | no | Viewer basic-auth username, default `admin`. |

Any other agentmemory variable (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
`AGENTMEMORY_AUTO_COMPRESS`, `AGENTMEMORY_AGENT_SCOPE`, …) is read straight from the
environment by the app.
