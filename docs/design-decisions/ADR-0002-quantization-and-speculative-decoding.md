# ADR-0002: FP8 + multi-token-prediction speculative decoding over plain INT4 quantization

**Status:** Accepted — production config for the FP8 model; INT4 and the wider model landscape
revisited as a follow-on, not yet production-decided.
**Related:** [performance.md](../performance.md) · [architecture.md](../architecture.md) ·
[README § Models](../../README.md#models-servermodelsjson)

## Context

Decode throughput on a single shared GPU is the direct latency budget for an interactive coding
agent — every token the model emits is on the critical path of a Codex turn, and the box serves every
concurrent session from the same weights. The constraints: fit comfortably in the VRAM of the target
instance (A10G 24 GB or L40S 48 GB), keep the OpenAI-style tool-calling format Codex requires (which
already ruled out the Mistral/Devstral family — see `architecture.md`), and maximize single-stream
decode speed without an unacceptable quality trade.

Rather than picking a quantization scheme off a spec sheet, I benchmarked three serving
configurations back-to-back on the **same hardware** (`g6e.xlarge`, L40S 48 GB, coding prompts,
`reasoning_effort=medium`) before choosing the production path.

## Options compared (measured, same box)

| Config | Decode throughput | Speedup | Notes |
|---|---|---|---|
| AWQ **INT4** + `--enforce-eager` | **~14 tok/s** | 1x (baseline) | No CUDA graphs, no speculation |
| **FP8** + CUDA graphs, no speculation | **~27 tok/s** | ~1.9x | Graphs recover throughput eager mode leaves on the table |
| **FP8 + MTP speculative decoding** (chosen) | **~55–60 tok/s** | **~4x–4.3x** | `enforce_eager: true` required for the speculator — mutually exclusive with CUDA graphs on the *main* model, yet still the fastest of the three |

Source: [`server/qwen3.8-fp8-mtp-serve.txt`](../../server/qwen3.8-fp8-mtp-serve.txt) (HF-download
production config, ~55–59 tok/s, ~78% draft acceptance) and
[`server/qwen38-fp8-streaming.txt`](../../server/qwen38-fp8-streaming.txt) (S3-streamed run, 60 tok/s,
84.8–96.4% draft acceptance, acceptance length 3.89/4). These are two different runs of the same
serving config, not two different numbers for the same run — see
[`performance.md`](../performance.md) for the full breakdown and why they're reported separately
rather than averaged.

## Decision

Serve the production model as **FP8 + multi-token-prediction speculative decoding**
(`--speculative-config '{"method":"qwen3_5_mtp","num_speculative_tokens":3,"enforce_eager":true}'`).
The speedup is not a rounding artifact: a non-speculative eager baseline (~14 tok/s) establishes that
MTP is doing real drafting work, not just benefiting from an unrelated optimization — the ~4.3x gap
between eager-INT4 and FP8+MTP, and the ~2.2x gap between FP8-alone and FP8+MTP, isolate speculation's
contribution specifically.

### Gotchas this decision surfaced

- The speculator's method name is **`qwen3_5_mtp`**, not `"mtp"` — the latter is silently accepted and
  loaded but never actually drafts (a config that "works" with zero error output and zero speedup).
- MTP requires `enforce_eager: true` in the speculative config, which disables CUDA graphs for the
  main model. Counterintuitively, eager-mode-with-speculation still beats graphs-without-speculation
  (~59 vs ~27 tok/s) — the speculator's token-per-step win outweighs what CUDA graphs would have
  recovered.
- The HF-download deploy needs a **≥200 GB root volume**: the `qwen3_5_mtp` method downloads a
  speculator/target model on top of the ~28 GB FP8 checkpoint, and a 100 GB root overflowed mid-load
  (`No space left on device: /root/.cache/huggingface`) in an earlier attempt.
- The model is multimodal (Qwen3VL-based) and pays a further ~20 s warmup for vision support on load;
  `--language-model-only` is noted as a future lever if vision is never used.

## The INT4 follow-on and the wider model landscape

Two things are explicitly *not* settled by this ADR, and are called out rather than silently folded
into the numbers above:

- **A separate INT4 quantization bake-off is in progress** (a parallel workstream, not yet landed as a
  `models.json` entry in this repo). Reported footprint figures are **FP8 ~29 GB vs. INT4 ~18.5 GB** —
  the FP8 figure is corroborated by this repo's own artifacts (30.9 GB of S3 objects including the MTP
  head and tokenizer, a ~28 GB checkpoint per the HF-download deploy notes, README's own "~29 GB"
  figure); the INT4 figure is **not yet a committed, in-repo measurement** and is reported here only
  as the current state of that external bake-off. **INT4 decode throughput on this hardware is not
  yet measured — pending.**
- **Expected quality delta, FP8 → INT4, is ~1.5–2.5 percentage points** on standard evals, per
  published third-party quantization benchmarks rather than an in-repo evaluation of this specific
  checkpoint — consistent with, for example, NVIDIA's TensorRT Model Optimizer comparisons showing
  FP8 post-training quantization retaining roughly 99% of BF16 quality against roughly 94–96% for
  INT4 AWQ on MMLU/GSM8K/HumanEval-style benchmarks (a gap in the same 1.5–2.5 point range). This is
  cited as external literature, not a claim about this deployment's own eval numbers.
- **Qwen3-Coder-Next** (Alibaba Qwen, released ~Feb–Mar 2026) is a hybrid-attention MoE model —
  80B total / 3B active parameters, 256K native context, trained specifically for agentic coding and
  tool-use workloads — and is a strong *landscape* candidate for a future `models.json` entry given
  how cheap a model swap already is in this architecture (one Terraform var + redeploy, no code
  change). It has **not been evaluated** against this deployment's hardware (A10G/L40S) or Codex's
  tool-calling format; it's noted here as the kind of option a `MODEL_KEY`-driven registry is built to
  make low-cost to try, not as a decision already made.

## Consequences

- Production serving is pinned to FP8 + MTP until the INT4 bake-off produces a comparable same-hardware
  throughput number — a quantization decision shouldn't be made on footprint alone when decode
  throughput is the actual bottleneck being optimized.
- The `kv_cache_dtype=fp8` KV-cache option (used on the AWQ models in this registry) is a separate,
  compounding lever from weight quantization — roughly doubling concurrent-session headroom on
  Ampere-class GPUs — and is tracked independently in `server/models.json` per model row.
