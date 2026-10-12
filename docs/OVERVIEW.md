# codex-selfhosted — Engineering Overview

A self-hosted LLM inference platform that runs the OpenAI Codex CLI — an agentic coding
assistant — against a self-managed vLLM serving stack on AWS GPU infrastructure, at zero cost
when idle. This document is the portfolio-level narrative: the problem, the architecture, the
engineering decisions that mattered, and the results I measured. For command-line usage see
[`README.md`](../README.md); for the systems view see [`architecture.md`](architecture.md); for
the "why" behind each hard call see [`design-decisions/`](design-decisions/); for the runbook see
[`operations.md`](operations.md); for benchmark data see [`performance.md`](performance.md).

## The problem

Paid LLM APIs bill per token and hand you zero control over the serving stack: no visibility into
batching behavior, no choice of quantization, no ability to swap in a faster model the day it
ships, and no way to drive total spend to zero between sessions. For an individual developer (or a
small team) running an agentic coding tool like Codex all day, that adds up — and it's a black
box. I built `codex-selfhosted` to own that stack end-to-end: the GPU, the inference server, the
scaling policy, and the client that drives it — while keeping the economics of a side project
(GPU billed only while warm) and the security posture of a managed service (no public endpoint,
ever).

The result is a working **LLM inference platform**, not a demo: a portable client, a vLLM-based
**model-serving layer** with pluggable quantization and speculative decoding, and a **Terraform-defined
GPU infrastructure stack** that stands up a new AWS account from scratch. It is `git clone`-and-go
on a second account, which is the test that separates a working platform from a one-off script.

## System at a glance

```
codex CLI  →  compatibility proxy (role-rewrite)  →  SSM tunnel (zero public ingress)  →  vLLM on an ECS/EC2 GPU task
                                                                                              │
                                                                               continuous batching, speculative
                                                                               decoding, FP8 quantization, S3
                                                                               weight-streamed cold start
```

Three layers, cleanly separated:

- **`bin/`** — the client. A single portable shell entrypoint (`codex-selfhosted`) that drives ECS/ASG
  scaling, opens an IAM-gated SSM tunnel, runs a small Python compatibility shim in front of it, and
  manages per-session isolation — plus an MFA helper for short-lived AWS credentials. No AWS account
  names are hardcoded; one config file per account makes the whole thing multi-account portable.
- **`server/`** — the GPU image. A vLLM-only Docker image with a JSON **model registry**
  (`models.json`) that resolves a `MODEL_KEY` to a full `vllm serve` invocation (model source,
  quantization, KV-cache dtype, tool-call parser, speculative-decoding config), plus an in-container
  watchdog that can self-terminate the service.
- **`infra/`** — the **Infrastructure as Code**. Terraform for the full GPU stack: ECR, a GPU
  Auto Scaling Group behind an ECS capacity provider, the ECS cluster/service/task definition, three
  IAM roles scoped to least privilege, and the two security groups that implement the zero-ingress
  network model.

## Key engineering decisions

Each of these is written up as a full ADR with the tradeoff analysis and (where available) the
measurement that drove it — see [`design-decisions/`](design-decisions/) for the complete reasoning.
Summarized here for scope and impact:

1. **[ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md) — S3 weight streaming over a baked
   image or HuggingFace download.** Cold-start and NAT-egress cost were both on the critical path for
   a scale-to-zero service (every `up` pays the cold-start tax). Streaming the FP8 checkpoint straight
   from an in-region S3 bucket into GPU memory via vLLM's Run:ai Model Streamer — instead of baking a
   34 GB image or downloading ~28 GB from HuggingFace through NAT on every cold start — cut the image
   to ~9 GB, made the weight load free (S3 gateway endpoint, no NAT), and is the fastest of the three
   paths measured.
2. **[ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md) — FP8 + multi-token
   speculative decoding over plain quantization.** Single-stream decode throughput on a one-GPU box is
   the direct bottleneck for an interactive coding agent. I benchmarked three serving configurations
   on the same hardware (AWQ-INT4 eager, FP8 + CUDA graphs, FP8 + MTP speculative decoding) before
   picking the production config — a controlled, same-box comparison rather than a spec-sheet
   decision.
3. **[ADR-0003](design-decisions/ADR-0003-single-gpu-deployment-config.md) — fixing a single-GPU rolling-deployment
   deadlock.** A one-GPU service running ECS's *default* rolling-update settings will wedge itself
   permanently on the first task-definition change: ECS tries to run two tasks during the rollover,
   and the second has nowhere to schedule. Root-caused from a stuck `PROVISIONING` task and fixed at
   the IaC layer (`deployment_maximum_percent = 100`, AZ rebalancing disabled) so it can't regress.
4. **[ADR-0004](design-decisions/ADR-0004-scale-to-zero-and-two-layer-autodown.md) — defense-in-depth
   scale-to-zero.** A single idle-timeout mechanism fails the moment its owning process dies (closed
   laptop, killed terminal) and leaves a GPU billing indefinitely. I built two independent auto-down
   paths — a client-side idle reaper and a server-side absolute time cap — that share one teardown
   routine, so a warm GPU can't be left running by any single point of failure.

## Measured results

Full methodology, raw figures, and what's still pending in [`performance.md`](performance.md).
Headlines:

| Dimension | Result |
|---|---|
| Decode throughput | **~4.3x** from a non-speculative FP8 baseline (~14 → ~59–60 tok/s) by adding multi-token-prediction speculative decoding on the same GPU |
| MTP draft acceptance | 84.8–96.4% (streamed-weights run), ~78% (HF-download baseline run) — speculation is doing real work, not padding |
| Image size | 34 GB baked → ~9 GB streamed (no model weights in the image) |
| Weight load time | 36.1 s (no speculator) / 53.8 s (with MTP) streamed from S3, vs. 100.9 s for the baked image |
| Cold-start egress cost | $0 — in-region S3 gateway endpoint, no NAT data charge, vs. ~28 GB of HuggingFace traffic per cold start on the download path |
| Idle cost | $0 — scale-to-zero on both the ECS service and the GPU ASG; `use_spot` cuts warm-hour cost ~65% further |

Where repo artifacts disagree or a number is a published third-party benchmark rather than an
in-repo measurement, `performance.md` says so explicitly — a measured number and an estimate are not
interchangeable, and I've kept them labeled as such rather than rounding away the difference.

## Engineering practices this repo demonstrates

- **System design under real constraints.** The network model (SSM-tunnel-only, isolated security
  group, zero public ingress), the cost-control model (two independent auto-down layers), and the
  concurrency model (one shared tunnel, N isolated `CODEX_HOME`s, vLLM continuous batching underneath)
  are all designed as explicit, stated tradeoffs — not defaults left in place.
- **Root-cause debugging, not symptom patching.** The single-GPU deployment deadlock (ADR-0003) was
  diagnosed from first principles (ECS rolling-update semantics vs. a one-task capacity ceiling) and
  fixed at the infrastructure-as-code layer so the class of bug can't reappear on the next `terraform
  apply`.
- **Benchmark-driven, not spec-sheet-driven, performance work.** The FP8/MTP decision (ADR-0002) came
  from three same-hardware configurations run back-to-back, not from reading a vendor benchmark and
  assuming it would transfer.
- **Honest validation boundaries.** Every serving configuration documents whether it was validated
  end-to-end, measured from component timings, or is a portable-but-unverified path (see
  [ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md)'s note on the registry path vs. the
  proven taskdef override) — the kind of distinction that matters once something this reaches a
  second engineer.
- **Full-stack ownership in a narrow footprint.** One person, three weeks, 27 commits
  (2026-09-22 → 2026-10-12): client UX, a request-compatibility shim for an API dialect gap between
  Codex and vLLM 0.30.0, GPU inference serving, performance tuning, cost engineering, and
  infrastructure-as-code — each layer small enough to read in one sitting, and each decision recorded
  as it was made rather than reconstructed after the fact.

## Scope

| Layer | What's there |
|---|---|
| Client | `bin/codex-selfhosted` (init/up/chat/exec/run/resume/status/down), `bin/codex-role-proxy.py` (Codex↔vLLM compatibility shim, unit-tested), `bin/aws-mfa.sh` (MFA-elevated session helper) |
| Server | `server/Dockerfile.gpu`, `server/entrypoint-gpu.sh` (model-registry-driven launcher), `server/models.json`, `server/self_down.py` + sidecar (self-termination backstop) |
| Infra | `infra/*.tf` — VPC (optional), two security groups, GPU ASG + launch template, ECS cluster/service/capacity provider, ECR, three IAM roles, application-autoscaling target |
| Tests | `tests/test_proxy.py` — unit coverage for every request-rewrite rule in the compatibility proxy |

This is a working, run-it-yourself system (`git clone` + `terraform apply` + `codex-selfhosted up`),
not a slide deck — every number in this document set traces back to a file in this repo or is
labeled as external.
