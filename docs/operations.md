# Operations

Day-to-day runbook for operating `codex-selfhosted`: the command lifecycle, multi-account operation,
the two auto-down layers, and the cost model. For first-time setup see the
[README Quickstart](../README.md#quickstart--use-an-existing-deployment); for the "why" behind the
scale-to-zero design see [ADR-0004](design-decisions/ADR-0004-scale-to-zero-and-two-layer-autodown.md).

## Command lifecycle

| Command | What it does under the hood |
|---|---|
| `init` | Idempotent config scaffold. `CODEX_ENV=default` (or unset) copies the committed `config.default.env` (pre-filled for the reference awsdev deployment — only `AWS_PROFILE` needs setting); any other `CODEX_ENV` copies the generic `config.example.env` for a fresh account, to be filled from `terraform output`. Never overwrites an existing env file. |
| `up` | `ensure_serving` (register the application-autoscaling target with `min-capacity=1`, wait for the model to serve — see [the wait loop](#the-up-wait-loop)) → `open_tunnel` (SSM port-forward) → `start_proxy` (compatibility shim) → `start_reaper` (Layer-1 idle watchdog). Idempotent at every step — re-running `up` against an already-warm box skips straight through. |
| `chat ["task"]` | Confirms the tunnel is up, ensures the proxy is running, builds/refreshes the **persistent** `CODEX_HOME` for this env, launches the interactive Codex TUI against it. Safe to run from any number of terminals at once — they share the tunnel and the model's continuous-batching scheduler. |
| `exec "task"` | Same preflight, but builds a **throwaway** `CODEX_HOME` (no MCP unless `CODEX_MCP_SET_EXEC` is set) and runs `codex exec` non-interactively; the temp home is removed on exit. |
| `run ["task"]` | `up` if the tunnel isn't already up, then `chat`. The one-command path for "I don't know/care if it's warm." |
| `resume [id\|--last\|--all]` | Refreshes the persistent `CODEX_HOME`'s provider/model pins, then `codex resume` against it. Sessions are cwd-filtered by default (`--all` to see sessions from other working directories). |
| `status` | Reports ECS desired/running counts, tunnel/proxy/reaper liveness (by pidfile + `kill -0`), and the currently served model (`GET /v1/models` through the tunnel). The fastest way to answer "is anything costing me money right now." |
| `down` | Runs the same `scale_to_zero` teardown every auto-down path uses: lift the autoscaling min floor, service desired→0, ASG min/desired→0, kill the local tunnel/proxy/reaper processes. |

### The `up` wait loop

Cold start isn't a dumb sleep-and-poll. The loop tails CloudWatch Logs for a specific marker
(`"Application startup complete"` / `"Uvicorn running on http"`) rather than guessing a fixed delay,
skips the wait entirely if a task is already running (so re-attaching to a warm box is instant), emits
a heartbeat roughly once a minute so a slow-but-normal boot never reads as a hang, and — the detail
that matters operationally — reads the GPU ASG's own last scaling-activity status on every heartbeat.
If AWS itself is reporting `Failed`/insufficient-capacity, `up` says so explicitly instead of letting
the operator wonder whether the model is still loading or the ASG can't get an instance at all.
Timeout is `CODEX_UP_TIMEOUT_MIN` (default 30 min) — raise it if a given instance type's capacity is
known to be tight in your AZ.

## Multi-account operation

One env file per account under `~/.config/codex-selfhosted/`, selected by `CODEX_ENV`:

```bash
CODEX_ENV=dev  source bin/aws-mfa.sh 111111 && CODEX_ENV=dev  bin/codex-selfhosted up
CODEX_ENV=prod source bin/aws-mfa.sh 222222 && CODEX_ENV=prod bin/codex-selfhosted up
```

Each env gets its own MFA credential file (`/tmp/mfa-env-<env>.sh`), tunnel pidfile, log files, and
persistent `CODEX_HOME` — state never crosses between accounts. The tunnel and role-proxy use the same
local ports (`CODEX_PORT` 8000 / `CODEX_PROXY_PORT` 8891) in every env, so run one env at a time per
machine unless you override the ports per env file.

## Tuning the auto-down layers

| Variable | Default | Layer |
|---|---|---|
| `CODEX_IDLE_REAPER` | `1` | Layer 1 — `0` disables the client-side idle reaper entirely (stay warm until manual `down`) |
| `CODEX_IDLE_TTL_MIN` / `CODEX_IDLE_TTL_SEC` | 30 min | Layer 1 — idle window before auto-down; `_SEC` exists specifically to make this testable without a 30-minute wait |
| `CODEX_REAP_POLL` | 60 s | Layer 1 — how often the reaper scrapes `/metrics` |
| `IDLE_MINUTES` (taskdef env, not client config) | 30 (when Layer 2 armed) | Layer 2 **idle** timeout — the GPU container watches vLLM `/metrics` itself and self-downs after this many minutes of no activity; `0` disables idle-down |
| `MAX_WARM_HOURS` (taskdef env, not client config) | unset (disabled) | Layer 2 **hard ceiling** — self-down after this many warm hours regardless of activity, independent of the client; `0`/unset disables the cap. Arming either `IDLE_MINUTES` or `MAX_WARM_HOURS` (with `SELF_CLUSTER`) turns Layer 2 on |
| `SELF_CLUSTER` / `SELF_SERVICE` / `SELF_ASG` / `SELF_SCALABLE` (taskdef env) | unset | Layer 2 — what the in-container watchdog is allowed to scale down (IAM-scoped to these exact resources, see `server/self-down-iam.json`) |

For an entryPoint-override taskdef (one that bypasses `entrypoint-gpu.sh`), Layer 2 ships as a
non-essential sidecar container instead — `server/max-warm-sidecar.json` is the live-deployed shape,
inlining the same sleep-then-self-down logic so the backstop still applies without needing the image's
own entrypoint.

## Troubleshooting

Day-to-day failure signatures and their fixes are kept in one place to avoid drift between docs — see
[README § Troubleshooting](../README.md#troubleshooting) (tunnel-down-after-sleep, missing/expired MFA
session, `up` timeouts and how to read them, the `400 Unknown message role: developer` signature of a
proxy that isn't in the path, and the single-GPU `PROVISIONING` deadlock from
[ADR-0003](design-decisions/ADR-0003-single-gpu-deployment-config.md)). Client-side logs live at
`/tmp/codex-selfhosted-{tunnel,proxy,reaper}-<env>.log`; GPU-side logs are in CloudWatch under
`$LOG_GROUP` (stream prefixes `vllm`, `max-warm`).

## Cost model

GPU compute is billed only while the ECS service is warm; both auto-down layers exist specifically so
that "while warm" means "while actually in use" (see
[ADR-0004](design-decisions/ADR-0004-scale-to-zero-and-two-layer-autodown.md)).

**Hourly rate** (us-east-2 spot pricing, 2026, per README): `g5.xlarge` (A10G 24 GB) **~$0.52/hr**;
`g6e.xlarge` (L40S 48 GB) **~$1.07/hr**. Setting `use_spot = true` in Terraform applies to the GPU ASG's
launch template and is reported at **~65% off** on-demand rates for the same instance type —
interruptible, which is an acceptable tradeoff for a dev-tool workload that can simply re-`up`.

**Idle cost: $0.** Both the ECS service and the GPU ASG scale to `min=0`/`desired=0` when down — there
is no "small" warm-standby tier, no reserved capacity sitting idle between sessions.

**Illustrative cost-per-token** (derived, not a directly measured metric): at the measured **~60 tok/s**
single-stream decode rate on `g6e.xlarge` spot (~$1.07/hr), that's roughly
**$0.005 per 1,000 output tokens** (≈ $5 per million) for one active stream —
`$1.07 / (60 × 3600 tok/hr) × 1000`. This is a **single-stream** figure; vLLM's continuous batching
serves multiple concurrent Codex sessions from the same GPU and the same weights, so the effective
cost per token for a team sharing the box falls further with concurrency — but aggregate
multi-session throughput hasn't been separately benchmarked here (see
[performance.md](performance.md) for what is and isn't measured), so that lower number is not
asserted as a hard figure.

**Weight-loading cost** is a separate, smaller line item covered in
[ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md): S3 storage for the streamed FP8
checkpoint (~$0.66/mo) versus ECR storage for the equivalent baked image (~$3.4/mo), plus the avoided
NAT-egress charge the HuggingFace-download path pays on every cold start.
