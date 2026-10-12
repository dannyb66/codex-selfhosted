# Performance

Every number below is labeled with where it came from and what kind of claim it is. Two labels matter
most: **Measured** (captured from an actual run, with the source file cited) and **Estimate**
(computed from component measurements, not a fresh end-to-end timing). Where a repo artifact disagrees
with another, both are shown — see [Cold start](#cold-start). Where a figure is a published
third-party benchmark rather than an in-repo measurement, it's marked **External**. Where something
hasn't been run yet, it's marked **Pending**. This is the same discipline
[ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md) and
[ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md) apply when citing these
numbers — a benchmark that doesn't say what it is isn't a benchmark, it's a vibe.

**Hardware for all measured numbers below:** `g6e.xlarge` (NVIDIA L40S, 48 GB, Ada/sm_89), coding
prompts, `reasoning_effort=medium`, captured on the project's awsdev reference deployment,
late-September 2026.

## Decode throughput and speculative decoding

| Configuration | Decode throughput | Speedup vs. eager-INT4 | MTP draft acceptance | Status | Source |
|---|---|---|---|---|---|
| AWQ INT4, `--enforce-eager` | ~14 tok/s | 1x (baseline) | n/a | Measured | `server/qwen3.8-fp8-mtp-serve.txt` |
| FP8 + CUDA graphs, no speculation | ~27 tok/s | ~1.9x | n/a | Measured | `server/qwen3.8-fp8-mtp-serve.txt` |
| FP8 + MTP (HF-download run, td :15) | ~55–59 tok/s | ~4x | ~78% | Measured | `server/qwen3.8-fp8-mtp-serve.txt` |
| FP8 + MTP (S3-streamed run) | 60 tok/s | ~4.3x | 84.8–96.4% (acceptance length 3.89/4) | Measured | `server/qwen38-fp8-streaming.txt` |

The two FP8+MTP rows are **two different runs of the same serving config** (one loading weights via
HF download, one via S3 streaming) — the weight-loading path shouldn't affect steady-state decode
speed, and the measured throughput is consistent across both (55–60 tok/s) within normal run-to-run
variance. The draft-acceptance gap (78% vs. 84.8–96.4%) is wider than that and is reported as-is
rather than averaged into a single number, since no artifact in the repo explains the gap (candidate
causes — prompt-set difference, sampling-seed variance, a vLLM point-version difference between the
two runs — aren't confirmed). A non-speculative baseline (~14 tok/s, eager) is included specifically
so the MTP speedup is attributable to real token drafting and not to an unrelated change.

## Model load time

| Load path | Time | Status | Source |
|---|---|---|---|
| Baked image (weights already in the container) | 100.9 s | Measured | `server/qwen38-fp8-streaming.txt` |
| S3 streaming, no speculator | 36.1 s | Measured | `server/qwen38-fp8-streaming.txt` |
| S3 streaming, with MTP | 53.8 s | Measured | `server/qwen38-fp8-streaming.txt` |

The MTP speculator's own warmup (CUDA-graph capture for the draft head) adds a further ~2–3 minutes
*after* the model is loaded but before the "Application startup complete" log line that gates the
client's cold-start wait — so streamed weight-load time (36–54 s) is a necessary but not sufficient
component of total cold start. See below.

## Cold start

This is the one place two repo artifacts disagree, so both are shown rather than collapsed into one
number:

| Figure | Value | Source | Status |
|---|---|---|---|
| Cold start, component sum (boot + load + warmup) | ~8.5–9 min | `server/qwen38-fp8-streaming.txt` | **Estimate** — the artifact explicitly flags this as "components measured; not a fresh end-to-end run" |
| Cold start, end-to-end (streamed) | ~11.5 min | `README.md`, `server/models.json` `_note` | Stated as measured/validated in both, but without the same component breakdown as the row above |
| Cold start, end-to-end (HF-download baseline) | ~17 min | `README.md` | Stated as measured; no separate component artifact in this repo |

These two streamed-path numbers (~8.5–9 min vs. ~11.5 min) were captured at different times and have
not been reconciled against a single fresh, timed `up` from `desired=0`. The honest summary: cold
start for the streamed path is **in the 8.5–11.5 minute range** depending on which capture you trust,
materially faster than the ~17 minute HF-download baseline either way, and a clean re-measurement
(time `bin/codex-selfhosted up` from a fully scaled-down state) would settle the exact number — that
run has not been done since this doc set was written.

## Image and storage footprint

| Artifact | Size | Status | Source |
|---|---|---|---|
| Baked image (weights included) | ~34 GB (33.96 GB) | Measured | `server/qwen38-fp8-streaming.txt` |
| Streamed image (no weights) | ~9 GB (8.97 GB) | Measured | `server/qwen38-fp8-streaming.txt` |
| FP8 checkpoint in S3 | 30.9 GB across 81 objects | Measured | `server/qwen38-fp8-streaming.txt` |
| S3 storage cost | ~$0.66/mo | Measured (AWS pricing applied to the above) | `server/qwen38-fp8-streaming.txt` |
| Baked-image ECR storage cost | ~$3.4/mo | Measured (AWS pricing applied to the above) | `server/qwen38-fp8-streaming.txt` |

## Quantization: FP8 vs. INT4

| Metric | FP8 (production) | INT4 | Status |
|---|---|---|---|
| Weight footprint | ~29 GB (consistent with the S3/checkpoint figures above) | ~18.5 GB | FP8: Measured (in-repo). INT4: **not yet an in-repo measurement** — reported from a parallel INT4 quantization workstream not yet landed as a `models.json` entry in this repo |
| Decode throughput (this hardware) | 55–60 tok/s (table above) | — | **Pending** — INT4 tok/s benchmark on this deployment's hardware is in progress, not yet available |
| Quality retention vs. BF16 | ~99% (typical for FP8 PTQ) | ~94–96% (typical for INT4 AWQ) | **External** — published third-party quantization benchmarks (e.g., NVIDIA TensorRT Model Optimizer comparisons on MMLU/GSM8K/HumanEval-style evals), not an in-repo evaluation of this checkpoint. Gap is ~1.5–2.5 percentage points, consistent with the ~1.4–1.5-point MMLU gap reported in those published comparisons. |

Full tradeoff discussion, including the Qwen3-Coder-Next landscape note, is in
[ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md).

## What's measured vs. what's still open

**Measured, in this repo, with a cited source:** single-stream decode throughput for all three
serving configs; MTP draft-acceptance rate (two runs); model load time by path; image sizes; S3/ECR
storage cost; FP8 weight footprint.

**Estimated, not re-verified end-to-end:** streamed cold start as a component sum (~8.5–9 min).

**External, not an in-repo evaluation:** FP8/INT4 quality-retention percentages; the Qwen3-Coder-Next
landscape comparison in ADR-0002.

**Pending — identified gaps, not yet measured:**
- INT4 decode throughput on this deployment's hardware.
- A single fresh, timed end-to-end `up` reconciling the two cold-start figures above.
- Aggregate multi-session decode throughput under concurrent load (continuous batching is architecturally
  expected to raise effective throughput per GPU — see [`architecture.md`](architecture.md#concurrency-model)
  — but has not been separately benchmarked; see the cost-per-token caveat in
  [`operations.md`](operations.md#cost-model)).
- End-to-end validation of the portable `MODEL_KEY=qwen38-stream` registry path against the proven
  taskdef-override path (see [ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md)).
