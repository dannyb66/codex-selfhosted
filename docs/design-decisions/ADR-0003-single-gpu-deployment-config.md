# ADR-0003: Pin single-task rolling-deployment config to stop a single-GPU deploy deadlock

**Status:** Accepted — fixed live, then codified in Terraform (`infra/ecs.tf`).
**Related:** [architecture.md](../architecture.md) · [operations.md](../operations.md)

## Context

The GPU service is deliberately capped to one task (`max_gpu_instances = 1` by default; the reference
deployment also runs `MAX_GPU=1` — one shared box serves every concurrent session via vLLM continuous
batching, see `architecture.md`). Each task requests exactly one GPU
(`resourceRequirements: [{type = "GPU", value = "1"}]` in `infra/ecs.tf`), and the ASG backing the
capacity provider has no second GPU to place a task on.

ECS's **default** rolling-deployment configuration assumes the opposite: that a service can
temporarily run *more* tasks than its steady-state count during a deployment
(`deploymentMaximumPercent = 200%`, `minimumHealthyPercent = 100%`), plus **Availability Zone
Rebalancing**, which actively tries to redistribute tasks across AZs. Both assume horizontal headroom
a one-task, one-GPU service structurally does not have.

## The failure mode

On any task-definition change (a new image tag, a model swap via `model_key`, a config change) under
default settings: ECS starts a **second** task to satisfy the 200% ceiling while the **first** task is
still running and still holding the GPU. The new task has nowhere to schedule — no second GPU exists —
and sits in `PROVISIONING` indefinitely. The old task never stops (minimum-healthy-percent is still
satisfied by it alone), so the deployment never completes and never fails outright: it just hangs.
This was first diagnosed live from exactly that symptom — a task stuck in `PROVISIONING` after a
routine taskdef update — not discovered in advance.

## Decision

Pin the service to a **stop-before-start** rollover instead of a rolling one, and disable AZ
Rebalancing (which requires `maximumPercent > 100` and is meaningless for a one-task service anyway).
In `infra/ecs.tf`:

```hcl
deployment_minimum_healthy_percent = 0
deployment_maximum_percent         = 100
availability_zone_rebalancing      = "DISABLED"   # requires AWS provider >= 5.82
```

This was applied as a live hotfix first —

```bash
aws ecs update-service ... --availability-zone-rebalancing DISABLED \
    --deployment-configuration "maximumPercent=100,minimumHealthyPercent=0"
```

— confirmed it unblocked the deploy, and was then **captured permanently in the IaC** so the same
deadlock can't reappear on a future `terraform apply` from a state that predates the fix, or on a
fresh account standing up the stack from scratch. Operational fix first, root cause second, then
closed the loop in Infrastructure as Code — not left as a runbook note that the next engineer (or the
next `apply`) could silently revert.

## Consequences

- **Explicit, scoped tradeoff: brief unavailability on every redeploy.** With `minimumHealthyPercent =
  0`, the old task is stopped *before* the new one starts — there is a gap, measured in the time it
  takes the new task to pull its image and the model to load, during which the service serves
  nothing. For a single-user or small-team interactive dev tool this is an acceptable, scoped
  tradeoff; it is explicitly **not** the right configuration for a service with an uptime SLA, which
  would need either a second GPU (and a real rolling deployment) or a blue/green cutover against two
  separate capacity pools.
- **Applies to any hand-run `update-service` too**, not just Terraform — the README's troubleshooting
  section calls this out directly so a manual deploy doesn't reintroduce the deadlock the IaC already
  closed.
- **A general lesson for GPU-scheduled workloads, not just this project:** ECS's (and most
  schedulers') default rollout assumptions are written for horizontally-scalable, resource-fungible
  services. A hard capacity ceiling per task (one exclusive GPU, no fractional sharing at the scheduler
  level) breaks that assumption silently — it doesn't error at `apply` time, it deadlocks at the next
  deploy, which is precisely the kind of gap that benefits from being written down once it's found.
