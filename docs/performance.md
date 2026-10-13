# Performance

Every number below is labeled with where it came from and what kind of claim it is. Two labels matter
most: **Measured** (captured from an actual run, with the source file cited) and **Estimate**
(computed from component measurements, not a fresh end-to-end timing). Where a fresh measurement
superseded an earlier in-repo estimate, the superseded figure is called out as corrected rather than
silently dropped — see [Cold start](#cold-start). Where a figure is a published
third-party benchmark rather than an in-repo measurement, it's marked **External**. Where something
hasn't been run yet, it's marked **Pending**. This is the same discipline
[ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md) and
[ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md) apply when citing these
numbers — a benchmark that doesn't say what it is isn't a benchmark, it's a vibe.

**Hardware for all measured numbers below:** `g6e.xlarge` (NVIDIA L40S, 48 GB, Ada/sm_89), coding
prompts, `reasoning_effort=medium`, captured on the project's awsdev reference deployment —
late-September 2026 for the FP8 and streaming numbers, and 2026-10-12 for the INT4 bake-off (same
L40S hardware class).

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

The streamed-path cold start is **~11.5 min**, measured end-to-end (validated live 2026-09-29). An
earlier ~8.5–9 min figure — a component sum (boot + weight load + warmup) that
`server/qwen38-fp8-streaming.txt` itself flagged as "components measured; not a fresh end-to-end
run" — proved over-optimistic: summing component timings under-counted real end-to-end overhead, and
the measured end-to-end value supersedes it. It is recorded here as a corrected estimate, not a second
live number competing with the 11.5-min measurement. (The superseded figure still lives in the
`server/` artifact, which is outside this doc set's edit scope — it is noted as corrected here rather
than silently contradicted.) Cold start depends on the weight-load path, so every row below names it:

| Figure | Load path | Value | Status | Source |
|---|---|---|---|---|
| Cold start, end-to-end | S3-streamed (FP8) | **~11.5 min** | **Measured** | `README.md`, `server/models.json` `_note` |
| Cold start, end-to-end | HF-download (FP8) | ~17 min | **Measured** | `README.md` |
| Cold start, end-to-end | HF-download (INT4) | ~12 min (model load ~135 s) | **Measured** — awsdev 2026-10-12 | INT4 bake-off run (not yet an in-repo artifact) |
| Cold start, component sum | S3-streamed (FP8) | ~8.5–9 min | **Superseded** — over-optimistic component sum, replaced by the ~11.5-min end-to-end measurement | `server/qwen38-fp8-streaming.txt` |

The streamed path is materially faster than the HF-download baseline at equal quantization (~11.5 vs.
~17 min, FP8). The INT4 checkpoint was benchmarked on the HF-download path at ~12 min — faster than
FP8-HF's ~17 min, a smaller checkpoint to pull and load; streaming it from S3, the obvious next step
to put INT4 on the production cold-start path, has not been run.

## Image and storage footprint

| Artifact | Size | Status | Source |
|---|---|---|---|
| Baked image (weights included) | ~34 GB (33.96 GB) | Measured | `server/qwen38-fp8-streaming.txt` |
| Streamed image (no weights) | ~9 GB (8.97 GB) | Measured | `server/qwen38-fp8-streaming.txt` |
| FP8 checkpoint in S3 | 30.9 GB across 81 objects | Measured | `server/qwen38-fp8-streaming.txt` |
| S3 storage cost | ~$0.66/mo | Measured (AWS pricing applied to the above) | `server/qwen38-fp8-streaming.txt` |
| Baked-image ECR storage cost | ~$3.4/mo | Measured (AWS pricing applied to the above) | `server/qwen38-fp8-streaming.txt` |

## Quantization: FP8 vs. INT4

An INT4 bake-off ran on the same class of hardware on **2026-10-12** (awsdev, L40S), benchmarking
`RedHatAI/Qwen3.8-27B-INT4` — a W4A16 body with a higher-precision (BF16) MTP draft head — against the
production FP8 + MTP config back-to-back. Both configs were timed with the **same methodology**:
wall-clock mean over 4 coding prompts, `max_tokens=600`, `temp=0`, single-stream. This checkpoint was
**HF-downloaded, not yet S3-streamed**, and is not yet a `models.json` entry.

| Metric | FP8 + MTP | INT4 + MTP | Status |
|---|---|---|---|
| Decode throughput, wall-clock mean (4 prompts) | ~50.7 tok/s | **71.4 tok/s** (range 65–79) | **Measured** — awsdev 2026-10-12, same-run back-to-back, HF-download |
| Decode throughput, server-side peak | ~59 tok/s | 75.2 tok/s | **Measured** — same run |
| MTP draft acceptance | ~64% | ~71% (59–81%), acceptance length 2.77–3.42 / 4 | **Measured** — same run |
| Runtime memory footprint | 28.9 GiB | **18.5 GiB** | **Measured** — awsdev 2026-10-12 (runtime GPU memory, a distinct quantity from the on-disk checkpoint sizes in the image/storage table above) |
| Quality vs. BF16 | ~99% (typical FP8 PTQ) | ~1.5–2.5 pts below FP8 | **External** — published third-party benchmarks (e.g., NVIDIA TensorRT Model Optimizer on MMLU/GSM8K/HumanEval-style evals) for INT4 **AWQ**; the benchmarked checkpoint is W4A16 with a BF16 MTP head, a different quantization scheme, so the figure is indicative, not a measurement of this checkpoint. The ~1.5–2.5-point delta is under the project's 3% quality bar. |

**INT4 + MTP is ~40% faster than FP8 + MTP on the same box** — 71.4 vs. 50.7 tok/s — at a ~1.5–2.5-point
quality cost that stays under the 3% bar, in ~36% less GPU memory (18.5 vs. 28.9 GiB). The comparison
is apples-to-apples: both figures are **wall-clock means over the same 4 coding prompts, measured
back-to-back in one 2026-10-12 session**. That is a stricter metric than the server-side steady-state
peaks reported for the earlier FP8 runs (the 55–60 tok/s figures in the decode table above) — wall-clock
mean includes prefill and per-request overhead, server-side peak does not, so the two are different
metrics rather than conflicting measurements. The INT4 run's outputs were spot-checked correct on all 4
prompts (a smoke check, not a formal eval). Streaming the INT4 checkpoint from S3 — the step that would
put it on the production cold-start path — has not been run.

Full tradeoff discussion, including the Qwen3-Coder-Next landscape note, is in
[ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md).

## What's measured vs. what's still open

**Measured, with a cited source:** single-stream decode throughput for all three in-repo serving
configs; MTP draft-acceptance rate; model load time by path; image sizes; S3/ECR storage cost; FP8
weight footprint; end-to-end streamed cold start (~11.5 min); and, from the 2026-10-12 awsdev INT4
bake-off, INT4 + MTP decode throughput, draft acceptance, and runtime memory footprint (HF-download,
not yet captured as an in-repo artifact).

**External, not an in-repo evaluation:** FP8/INT4 quality-retention figures (published AWQ benchmarks,
not this checkpoint); the Qwen3-Coder-Next landscape comparison in ADR-0002.

**Superseded:** the ~8.5–9 min component-sum cold-start estimate, replaced by the ~11.5-min end-to-end
measurement.

**Pending — identified gaps, not yet measured:**
- S3-streaming the INT4 checkpoint and landing it as a `models.json` entry — the bake-off ran on the
  HF-download path, so the streamed cold start and the portable registry path for INT4 have not been run.
- Aggregate multi-session decode throughput under concurrent load (continuous batching is architecturally
  expected to raise effective throughput per GPU — see [`architecture.md`](architecture.md#concurrency-model)
  — but has not been separately benchmarked; see the cost-per-token caveat in
  [`operations.md`](operations.md#cost-model)).
- End-to-end validation of the portable `MODEL_KEY=qwen38-stream` registry path against the proven
  taskdef-override path (see [ADR-0001](design-decisions/ADR-0001-s3-weight-streaming.md)).
