# ADR-0004: Two independent auto-down layers, plus a capacity-aware `up`

**Status:** Accepted — Layer 1 and Layer 2 are both live; Layer 2 is opt-in per taskdef and inert
unless configured.
**Related:** [architecture.md](../architecture.md#scale-to-zero-lifecycle) ·
[operations.md](../operations.md) · [ADR-0001](ADR-0001-s3-weight-streaming.md) (cold-start cost is
the other half of this cost-control story)

## Context

GPU compute is the dominant cost of this system, and the entire economic argument for self-hosting
depends on the box actually being at $0 when nobody's using it. "Scale-to-zero" is the target; the
question is how to make the *down* side of that as reliable as the *up* side, given that the thing
most likely to trigger it is a human forgetting — closing a laptop, killing a terminal, losing a
network connection mid-session — rather than a clean `down`.

A single idle-timeout mechanism has an obvious single point of failure: whatever process owns the
timer has to keep running for the timer to fire. If that process is the client (on the developer's
laptop) and the laptop goes to sleep or the terminal is killed, the timer dies with it and the GPU
stays warm — billable — indefinitely, with nothing left to notice.

## Decision

Two independent auto-down paths, with no shared dependency between them, both terminating in the same
teardown code:

### Layer 1 — client-side idle reaper (idle-based)

`up` forks a background watchdog (`bin/codex-selfhosted __reap`) that polls vLLM's own `/metrics`
endpoint through the tunnel every `CODEX_REAP_POLL` seconds (default 60), reading
`vllm:num_requests_running`/`waiting` and the cumulative `vllm:request_success_total` counter. If
there's no running/waiting request *and* the success counter hasn't moved since the last poll, the
idle clock keeps ticking; once idle time reaches `CODEX_IDLE_TTL_MIN` (default 30 minutes), it calls
the same `scale_to_zero` routine manual `down` uses. Polling the model's own request metrics — not a
keystroke timer or a "has a terminal been closed" heuristic — means a long-running `exec` or an
idle-but-still-open `chat` are told apart correctly.

### Layer 2 — server-side self-down (idle + max-warm, from inside the container)

An in-container watchdog that does not depend on the client having ever existed. It polls vLLM
`/metrics` (the same activity signal Layer 1 uses) and scales to zero after `IDLE_MINUTES` of no request
activity **or** a `MAX_WARM_HOURS` absolute ceiling — whichever comes first. The idle timeout is what
makes it catch boxes brought up *outside* the client `up` (AWS CLI, a redeploy), which Layer 1 never
sees; the hard cap is the last-resort guarantee. Two deploy shapes, same logic:

- **Image-entrypoint taskdefs:** `entrypoint-gpu.sh` runs `server/self_down.py` in the background; it
  watches `/metrics` and scales the ECS service (and, if configured, the application-autoscaling target
  and the ASG) to zero using the task role's own IAM permissions (`server/self-down-iam.json`, scoped to
  exactly one service ARN plus the two autoscaling actions it needs — not a wildcard).
- **entryPoint-override taskdefs** (which bypass `entrypoint-gpu.sh` entirely): the same logic ships as
  a non-essential **sidecar container** (`server/max-warm-sidecar.json` + `max-warm-sidecar-entrypoint.sh`).
  The minimal `gpu-stream` streaming image does not bake `self_down.py`, so the live-deployed sidecar
  **inlines** the identical idle+max-warm watch-then-self-down logic rather than calling it.

This is a true backstop: it requires nothing from the client, the developer's laptop, or the network
path between them — only that the taskdef sets `IDLE_MINUTES` and/or `MAX_WARM_HOURS` plus
`SELF_CLUSTER`/`SELF_SERVICE` (and is inert, by construction, on any taskdef that doesn't).

### Convergent teardown

Both layers — and the manual `down` command — call the same shape of teardown: lift the
application-autoscaling min-capacity floor back to 0, set the ECS service's desired count to 0, drain
the ASG (min/desired 0), and (client-side only) kill the tunnel, proxy, and reaper processes. No path
can leave the system half-torn-down (GPU billing with no reachable tunnel, or a tunnel open with no
GPU behind it).

### Capacity-aware `up`

The cold-start wait loop doesn't just poll-and-time-out. Each heartbeat it also reads the GPU ASG's
**own most recent scaling-activity status**
(`aws autoscaling describe-scaling-activities`); if AWS itself reports a `Failed` activity for
insufficient instance capacity, `up` surfaces that specific diagnosis instead of a generic "still
waiting" message — turning "is this hung or just slow?" from a guess into a read of the actual
signal, and pointing at a concrete remediation (add a subnet in another AZ for a second capacity
pool) rather than leaving the operator to go spelunking in CloudWatch mid-incident.

## Consequences

- **Both layers are independently disableable** (`CODEX_IDLE_REAPER=0`; `MAX_WARM_HOURS=0` or unset)
  and **inert by default** where not configured — Layer 2 adds zero behavior to a taskdef that
  doesn't set its environment variables, so it's safe to leave the capability in the image unused.
- **No cost surprise is more than one layer away.** Idle-but-forgotten is caught by Layer 1
  (`CODEX_IDLE_TTL_MIN`) *and*, client-independently, by Layer 2's own idle timeout (`IDLE_MINUTES`) — so
  a box upped outside the client (AWS CLI, a redeploy) that Layer 1 never sees still downs on idle, and
  `MAX_WARM_HOURS` is the absolute last-resort cap behind both. Layer 1 runs on the client, Layer 2 inside
  the task, so a failure of one (dead laptop, broken tunnel) doesn't disable the other.
- **Observability is symmetric with control.** `status` reports reaper liveness alongside tunnel/proxy
  state and the served model, so "is this costing me money right now, and why" is always a single
  command away rather than something to reconstruct from CloudWatch after the fact.
