# ADR-0002: FP8 + multi-token-prediction speculative decoding over plain INT4 quantization

**Status:** Accepted — production config for the FP8 model. The INT4 follow-on has now been
benchmarked (2026-10-12: INT4 + MTP ~40% faster than FP8 + MTP at a sub-3% quality cost on the same
L40S) but is not yet S3-streamed or landed as production; the wider model landscape remains open.
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

Two things sit outside this ADR's production decision and are called out rather than silently folded
into the numbers above — the INT4 follow-on (now benchmarked, not yet landed) and the wider model
landscape:

- **The INT4 bake-off has now run (awsdev, L40S, 2026-10-12)** — the measurement the first draft of
  this ADR was waiting on. Benchmarking `RedHatAI/Qwen3.8-27B-INT4` (a W4A16 body with a
  higher-precision BF16 MTP draft head) against the production FP8 + MTP config back-to-back on the
  same hardware, with one methodology (wall-clock mean over 4 coding prompts, `max_tokens=600`,
  `temp=0`, single-stream), **INT4 + MTP decoded at 71.4 tok/s vs. 50.7 tok/s for FP8 + MTP — ~40%
  faster** — at ~71% MTP draft acceptance (acceptance length 2.77–3.42 / 4) and in an **18.5 GiB**
  runtime footprint vs. **28.9 GiB** for FP8. This confirms the premise of this ADR: decode throughput,
  not footprint, is the axis that matters, and the smaller-weight quantization wins it (fewer bytes of
  weights to move per decode step on a bandwidth-bound GPU). It also shows INT4 is *not* inherently
  incompatible with speculation — the ~14 tok/s eager-INT4 row in the table above was INT4 with **no
  CUDA graphs and no speculation**, so that figure measures eager-vs-MTP, not INT4-vs-INT4. Caveats
  that bound the result: the checkpoint was **HF-downloaded, not yet S3-streamed**, and is **not yet a
  `models.json` entry**; outputs were spot-checked correct on all 4 prompts (a smoke check, not a
  formal eval). The 18.5 vs. 28.9 GiB figures are runtime GPU memory, a distinct quantity from the
  on-disk checkpoint sizes (~29–30.9 GB FP8) this repo records elsewhere.
- **Expected quality delta, FP8 → INT4, is ~1.5–2.5 percentage points** on standard evals — under the
  project's 3% quality bar — per published third-party quantization benchmarks rather than an in-repo
  evaluation of this specific checkpoint. For example, NVIDIA's TensorRT Model Optimizer comparisons
  show FP8 post-training quantization retaining roughly 99% of BF16 quality against roughly 94–96% for
  INT4 AWQ on MMLU/GSM8K/HumanEval-style benchmarks (a gap in the same 1.5–2.5-point range). Note the
  published figures are for INT4 **AWQ**, whereas the benchmarked checkpoint is **W4A16 with a BF16 MTP
  head** — a different quantization scheme — so the delta is indicative, not a measurement of this
  checkpoint. This is cited as external literature, not a claim about this deployment's own eval numbers.
- **Qwen3-Coder-Next** (Alibaba Qwen, released ~Feb–Mar 2026) is a hybrid-attention MoE model —
  80B total / 3B active parameters, 256K native context, trained specifically for agentic coding and
  tool-use workloads — and is a strong *landscape* candidate for a future `models.json` entry given
  how cheap a model swap already is in this architecture (one Terraform var + redeploy, no code
  change). It has **not been evaluated** against this deployment's hardware (A10G/L40S) or Codex's
  tool-calling format; it's noted here as the kind of option a `MODEL_KEY`-driven registry is built to
  make low-cost to try, not as a decision already made.

## Consequences

- Production serving stays pinned to FP8 + MTP **until the INT4 checkpoint is S3-streamed and landed as
  a `models.json` entry**. The same-hardware throughput number the earlier version of this ADR was
  waiting on now exists — INT4 + MTP is ~40% faster at a sub-3% quality cost — so the remaining gap is
  operational, not evidentiary: stream the weights onto the production cold-start path and run the
  portable registry row end-to-end, not run another benchmark. The original principle holds — a
  quantization decision shouldn't be made on footprint alone when decode throughput is the actual
  bottleneck — and the throughput evidence now points at INT4.
- The `kv_cache_dtype=fp8` KV-cache option (used on the AWQ models in this registry) is a separate,
  compounding lever from weight quantization — roughly doubling concurrent-session headroom on
  Ampere-class GPUs — and is tracked independently in `server/models.json` per model row.
