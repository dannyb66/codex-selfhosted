# Case study: self-hosted LLM inference platform for agentic coding (staff-level AI infrastructure)

> First-person, portfolio-level narrative. Technical depth lives in
> [OVERVIEW.md](OVERVIEW.md), [architecture.md](architecture.md),
> [design-decisions/](design-decisions/), [operations.md](operations.md),
> [performance.md](performance.md), [security.md](security.md), [models.md](models.md) —
> every claim below links to its evidence. Built 2026-09-22 → 2026-10-12, one person,
> three weeks, on an individual developer's budget.

## The problem

Agentic coding tools bill against a public LLM API: per-token cost at all hours, no control over
the serving stack (batching, quantization, speculative decoding, context limits), and no path to
$0 between sessions. I wanted the economics of a side project with the reliability of a managed
service, and a stack I could actually reason about — so I built one end-to-end: **client,
inference server, GPU infrastructure, security model, and cost control**, deployed as
`git clone` + `terraform apply` + `up`.

## What it is

An OpenAI-API-compatible **LLM inference platform** on AWS: a vLLM serving layer with a
pluggable **model registry** (quantization, KV-cache dtype, tool-call parser, speculative-decoding
config per model), a Terraform-defined GPU stack (ECS + GPU ASG + capacity provider, scale-to-zero),
a zero-public-ingress network model (IAM-gated SSM tunnel only), and a portable multi-account
client that drives the whole lifecycle. It is `git clone`-and-go on a second account — the test
that separates a platform from a one-off script.

## Headline results (all measured, all cited in [performance.md](performance.md))

| Dimension | Result |
|---|---|
| **Decode throughput** | **4.3×** over the non-speculative eager baseline (~14 → ~59–60 tok/s) by adding **multi-token speculative decoding**; a follow-on **INT4 (W4A16) + MTP** config measured **~40% faster still** (71.4 vs 50.7 tok/s) at a sub-3% quality cost and 18.5 vs 28.9 GiB footprint |
| **Cold start** | ~11.5 min end-to-end via **S3 weight streaming** (Run:ai streamer, 53.8 s weight load with MTP / 36.1 s without) vs ~17 min for the HF-download path; image 34 GB baked → ~9 GB streamed |
| **Cost per cold start** | **$0 egress** — in-region S3 gateway endpoint replaces ~28 GB of NAT-billed HF download traffic; S3 storage ~$0.66/mo vs ~$3.4/mo ECR for a baked image |
| **Idle cost** | **$0** — scale-to-zero on ECS service + GPU ASG, enforced by two independent auto-down layers; spot pricing adds ~65% off warm-hour cost when enabled |
| **Concurrency** | One GPU serves N concurrent sessions via **continuous batching** (one shared tunnel, isolated per-session state) — per-developer cost falls with team size |

## The engineering calls (each has a full ADR with the tradeoff analysis)

1. **Benchmark-driven inference tuning, not spec sheets** — three same-hardware serving configs
   (AWQ-INT4 eager, FP8 + CUDA graphs, FP8 + MTP speculative) run back-to-back before picking
   production; the counterintuitive finding (eager + speculation beats graphs + none) is
   documented with the measurements, along with the silent-failure gotchas (`mtp` vs
   `qwen3_5_mtp` method names that "work" with zero speedup) —
   [ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md).
2. **Weight delivery as a first-class decision** — streaming vs baked vs download analyzed on both
   axes that matter for a scale-to-zero service: recurring cold-start latency *and* recurring
   egress cost. Streaming won on both — [ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md).
3. **Root-causing an infrastructure deadlock** — a single-GPU ECS service wedged permanently on its
   first taskdef change (default rolling config assumes horizontal headroom that doesn't exist).
   Diagnosed from ECS semantics, fixed in Terraform so the class of bug can't regress —
   [ADR-0003](design-decisions/ADR-0003-single-gpu-deployment-config.md).
4. **Defense in depth for cost control** — a client-side idle reaper *and* a server-side
   absolute-cap watchdog (which fires even if the laptop is closed), sharing one teardown routine
   so no single point of failure leaves a GPU billable —
   [ADR-0004](design-decisions/ADR-0004-scale-to-zero-and-two-layer-autodown.md).
5. **Zero-ingress security** — SSM-tunnel-only access, MFA-gated least-privilege IAM (task role
   empty for HF models; S3-scoped to one bucket for streaming), isolated security group,
   IMDSv2 required — [security.md](security.md).
6. **Compatibility as a small owned shim, not a fork** — a 140-line unit-tested proxy bridges the
   Codex↔vLLM Responses-API dialect gap (developer role, content chunks, echoed reasoning items),
   and the model registry isolates tool-format incompatibilities (e.g. Mistral-family models) so
   model swaps stay a one-variable change — [models.md](models.md).

## Role fit

Keyword and framing validated against 8 live staff/principal postings (Anthropic ×3, Databricks
×2, Together AI ×2, CoreWeave ×1, Oct 2026) — the terms below are the ones those postings actually
use, mapped to what this project demonstrates.

This work maps directly to **staff/principal AI infrastructure, ML platform, and inference
optimization** roles:

- **LLM inference engineering**: LLM serving (vLLM), continuous batching, speculative decoding
  (MTP), quantization (FP8, W4A16/INT4, AWQ), KV-cache memory management, decode throughput /
  latency (TTFT / TPOT), tool-calling/function-calling and agentic tool-use, reasoning models, MCP,
  open-weights models.
- **GPU infrastructure & capacity**: GPU instance selection and right-sizing (A10G vs L40S),
  autoscaling and scale-to-zero capacity design, spot/on-demand economics, cold-start optimization,
  deployment reliability on constrained capacity (the single-GPU deadlock).
- **Cloud & FinOps**: AWS (ECS/EC2, SSM, ECR, S3 gateway endpoints, CloudWatch), Infrastructure as
  Code (Terraform), cost-per-token analysis, egress elimination, least-privilege IAM, and secrets
  handling. The orchestration patterns here (capacity providers, autoscaling targets, per-task
  isolation) are the same ones Kubernetes expresses as Karpenter / HPA — the stack is Terraform-
  portable to GCP/Azure even though this deployment is validated on AWS.
- **Reliability & operations** — the most common staff-level signal in the postings: SLO-driven
  operation, high-availability reasoning, observability-first design (Prometheus `/metrics`,
  CloudWatch, per-process logs), two independent self-down paths as defense-in-depth, and an
  on-call-able runbook. The system is built to be operated and paged, not just demoed.
- **Staff-level signals**: 0→1 end-to-end ownership across client, serving, infra, and cost;
  ADR-style decision records with measured outcomes; benchmark methodology discipline (measured vs
  estimated vs external, labeled); root-cause failure diagnosis from first principles; and a system
  designed for handoff — every layer readable in one sitting, every decision recorded as made.

Honest scope boundaries, stated up front: this is an **inference** platform — no model training,
fine-tuning, or RAG; it is validated on **AWS ECS** (the Kubernetes-equivalent
orchestration/autoscaling concepts transfer directly, but I did not build it on K8s); and the
single-GPU aggregate throughput benchmark (multi-session continuous batching) is identified as
pending in [performance.md](performance.md) rather than asserted.
