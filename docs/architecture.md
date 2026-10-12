# Architecture

`codex-selfhosted` runs the OpenAI Codex CLI — an agentic coding assistant — against a self-hosted,
OpenAI-API-compatible **vLLM inference server** on an AWS GPU, at $0 when idle. This document is the
systems view: components, data flow, concurrency model, and the zero-ingress networking/security
model. For the portfolio-level narrative see [`OVERVIEW.md`](OVERVIEW.md); for the "why" behind each
hard engineering call, see [`design-decisions/`](design-decisions/); for day-to-day commands and the
cost model, see [`operations.md`](operations.md).

## The request path

```
┌─ your laptop ────────────────────────────────────────────────────────────────────┐
│ codex CLI (N terminals)                                                          │
│   │  wire_api=responses, base_url=http://localhost:8891/v1                       │
│   ▼                                                                              │
│ role-proxy (127.0.0.1:8891)   bin/codex-role-proxy.py                            │
│   │  rewrites: developer→system, flattens input_text chunks, strips              │
│   │  echoed `reasoning` items, merges system msgs → single leading system        │
│   ▼                                                                              │
│ SSM port-forward (localhost:8000)  — IAM-gated, per-user, no public ingress       │
└───┼──────────────────────────────────────────────────────────────────────────────┘
    ▼  (over the AWS session channel; the GPU box has no inbound rules from the internet)
┌─ AWS: ECS service (1 GPU instance) ──────────────────────────────────────────────┐
│ vLLM /v1/responses  :8000   (tool-calling + reasoning parsers per model)         │
│   • continuous batching  → many concurrent Codex sessions share one GPU          │
│   • scale-to-zero: service + ASG min 0; `up` → 1, `down` → 0                     │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Why two local hops: the **role-proxy** exists only because Codex speaks the OpenAI Responses API
in a dialect vLLM 0.30.0 rejects (`developer` role, typed content chunks) — see
[Model ↔ Codex compatibility](../README.md#model--codex-compatibility-important) in the README. It
is deliberately a standalone ~140-line shim with its own unit tests (`tests/test_proxy.py`), not a
vLLM fork — a narrow, replaceable layer rather than a patch to a vendored dependency.

## Components

| Component | Files | Role |
|---|---|---|
| Client CLI | `bin/codex-selfhosted` | `init` / `up` / `chat` / `exec` / `run` / `resume` / `status` / `down`; drives ECS/ASG scaling, opens the tunnel, manages proxy + idle reaper; builds a per-session `CODEX_HOME` |
| Compat proxy | `bin/codex-role-proxy.py` | Codex↔vLLM request rewriting (developer→system etc.), streams responses through untouched |
| MFA helper | `bin/aws-mfa.sh` | `sts get-session-token` with the user's virtual MFA → 12h `AWS_*` creds in `/tmp/mfa-env-<env>.sh` |
| GPU image | `server/Dockerfile.gpu`, `server/entrypoint-gpu.sh`, `server/models.json` | vLLM-only image; `MODEL_KEY` registry resolves a model row to the full serve command (quantization, KV-cache dtype, tool/reasoning parsers, speculative-decoding config); in-container max-warm watchdog |
| Self-down | `server/self_down.py`, `server/max-warm-sidecar.json` | Server-side (Layer-2) scale-to-zero after an absolute warm-time cap, independent of the client |
| Infra (IaC) | `infra/*.tf` | VPC/SGs (optional), ECR, GPU ASG + launch template, ECS capacity provider, cluster, service, 3 IAM roles, application-autoscaling target |
| Config | `config.example.env`, `config.default.env`, `~/.config/codex-selfhosted/<env>.env` | Per-account settings; the client sources exactly one file per `CODEX_ENV` — no account name is hardcoded anywhere in `bin/` |
| Tests | `tests/test_proxy.py` | Unit tests for every proxy rewrite rule |

## Concurrency model

- **One shared tunnel, N sessions.** The SSM port-forward binds one local port for the whole env;
  every terminal's `codex` process talks to it. The GPU handles concurrency via vLLM **continuous
  batching** (up to `--max-num-seqs` in-flight sequences, with prefix caching and an FP8 KV-cache
  option to roughly double concurrent-session headroom), so cost per developer falls as the team
  shares one box — the same economic argument that drives shared inference infrastructure at any
  scale.
- **Isolation per session.** Each `chat`/`exec` gets its own `CODEX_HOME` (a generated
  `config.toml` pinning the provider, model, reasoning effort, and a curated MCP subset).
  `chat`/`resume` share one *persistent* home per env so session rollouts survive for `resume`;
  `exec` uses a throwaway home. Config is written atomically (temp file + `mv`) so concurrent
  sessions never read a half-written file.

## Scale-to-zero lifecycle

```
            ┌────────────────────────────────────────────────────────┐
            │  down (desired=0, ASG min/desired=0)  →  $0 compute     │
            └──────────────▲───────────────────────────▲─────────────┘
                           │                           │
                    `down` (manual)          reaper: idle ≥ TTL
        ┌─────────────────┴─────────┐        (Layer 1, client-side)
        │  up:                      │
        │  1. app-autoscaling min=1 │   or: server max-warm watchdog
        │  2. ECS desired=1         │   (Layer 2, in-container,
        │  3. wait model serve      │    fires even if the client
        │  4. SSM tunnel            │    is gone — closed laptop)
        │  5. role-proxy            │
        │  6. idle reaper           │
        └───────────────────────────┘
```

Both auto-down paths converge on the same teardown (min-capacity floor lifted, service desired=0,
ASG drained, tunnel/proxy/reaper processes killed) so state can't be left half-open. Full rationale:
[ADR-0004 — scale-to-zero and two-layer auto-down](design-decisions/ADR-0004-scale-to-zero-and-two-layer-autodown.md).
`up`'s cold-start wait also distinguishes a slow-but-normal boot from an ASG capacity stall (reads
the ASG's last scaling-activity status) rather than just timing out silently — see
[`operations.md`](operations.md#the-up-wait-loop).

## Zero-trust networking and security model

- **No public ingress, anywhere.** The GPU task has no public IP and sits behind an **isolated
  security group** whose only inbound rule is the vLLM port, scoped to the host security group —
  not `0.0.0.0/0`, not even the VPC CIDR. The only path in is an **SSM port-forwarding session**,
  which is IAM-gated (`ssm:StartSession`) and per-user, not a shared credential or an open port.
- **Control plane vs. data plane**, separately authenticated:
  - *Data plane* (token streaming): laptop → SSM channel → vLLM, carried over the same IAM-elevated
    session used for the tunnel. No API keys on the wire, no load balancer, no DNS name to guess.
  - *Control plane* (scaling, tunnel lifecycle): the client calls ECS/ASG/SSM/CloudWatch APIs
    directly with the caller's MFA-elevated session, using only the least-privilege actions listed
    in the README prerequisites. The GPU container's only control-plane power is *scaling itself to
    zero* (the Layer-2 watchdog) — it cannot scale up, and its IAM policy
    (`server/self-down-iam.json`) is scoped to exactly that one service ARN plus the two unscoped
    autoscaling actions it needs.
- **Short-lived, MFA-elevated credentials.** `bin/aws-mfa.sh` exchanges a virtual-MFA code for a
  12-hour STS session token and writes only `AWS_*` values to a `chmod 600` temp file — no long-lived
  access keys are read from or written into the repo or the config files.
- **Least-privilege IAM, three separate roles** (`infra/iam.tf`): an ECS *execution* role (pull image,
  write logs), an EC2 *instance* role (register with the cluster, carry the SSM agent — this is what
  makes the tunnel reachable), and a *task* role that is empty by default and gains exactly
  `s3:GetObject`/`ListBucket`/`GetBucketLocation` on one named bucket when weight streaming is
  configured — never a wildcard resource.

## Observability

- **Client side**: `status` reports service desired/running counts, tunnel/proxy/reaper liveness, and
  the currently served model; per-process logs land in
  `/tmp/codex-selfhosted-{tunnel,proxy,reaper}-<env>.log`.
- **GPU side**: vLLM exposes a Prometheus `/metrics` endpoint (scraped through the tunnel — the idle
  reaper polls it for request-activity detection); container and watchdog logs ship to CloudWatch
  Logs (`LOG_GROUP`, stream prefixes `vllm` and `max-warm`). Cold-start progress is gated on a
  specific log line (`Application startup complete`), and the capacity-aware wait loop in `up`
  distinguishes "still booting" from "ASG can't get instance capacity" by reading the ASG's own
  scaling-activity status — see [`operations.md`](operations.md) for the full signal.

## Model ↔ Codex compatibility (summary)

Two independent compatibility layers make this work, both owned by this repo rather than patched
into vLLM or Codex:

1. **API-dialect gap (affects every served model).** Codex speaks the OpenAI *Responses* API with a
   `developer` role and typed `input_text` content chunks; vLLM 0.30.0 rejects both. `codex-role-proxy.py`
   rewrites requests in flight (streaming the response back untouched) so any served model works with
   Codex until upstream vLLM adds `developer`-role support.
2. **Tool-format fit (per model family).** Qwen-family models (`qwen3_coder`/`hermes` parsers) speak
   OpenAI-style tool calls and work with Codex out of the box; Mistral-family models (Devstral,
   `mistral` parser) use a tool-call-id format Codex's client rejects and are not Codex-compatible
   regardless of the proxy — they're driven by other agentic tools instead (OpenHands, mini-SWE-agent).

Full model registry, VRAM/quantization notes, and the compatibility matrix:
[README.md § Models](../README.md#models-servermodelsjson).
