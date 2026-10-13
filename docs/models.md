# Models

The GPU image serves whatever [`server/models.json`](../server/models.json) says it should: the
Terraform var `model_key` picks a registry row, `entrypoint-gpu.sh` resolves it into a full
`vllm serve` command, and redeploying the taskdef is the entire model-swap procedure. This doc
explains the registry rows, the sizing math behind them, and the Codex compatibility constraints
that shape which models are usable here at all.

## Registry rows

| key | checkpoint | quant | GPU | ctx | serve config highlights |
|---|---|---|---|---|---|
| `instruct-14b` | Qwen/Qwen2.5-14B-Instruct-AWQ | AWQ (int4 weights) | g5.xlarge (A10G 24 GB) | 32k | `hermes` tool parser; fp8 KV cache; ~14 GB VRAM |
| `coder-30b` | cpatonn/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit | AWQ (auto-detected) | g5.2xlarge (A10G 24 GB); g6e.xlarge (L40S 48 GB) for full MCP + concurrency | 65k (16–32k practical on A10G) | `qwen3_coder` parser; `enforce_eager` + 0.95 mem-util on A10G to trade CUDA-graph speed for KV headroom |
| `qwen38-stream` | Qwen/Qwen3.8-27B-FP8 | FP8 (auto-detected) | g6e.xlarge (L40S 48 GB, Ada sm_89 required) | 65k | weights **streamed from S3** (runai_streamer); FP8 + MTP speculative decoding (`qwen3_5_mtp`); ~60 tok/s measured |
| `qwen38-int4-stream` | RedHatAI/Qwen3.8-27B-INT4 | W4A16 body + **BF16 lm_head/MTP head** (auto-detected; pass no `--quantization`) | g6e.xlarge (L40S 48 GB) | **256k** | streamed from S3; INT4 + MTP (`method: "mtp"`, Marlin kernel); 71.4 tok/s measured — ~40% faster than the FP8 row, 18.5 GiB footprint |
| (awsdev-only) `devstral-small-2` | Devstral Small 2 24B (Mistral3) AWQ | AWQ | g5.2xlarge (A10G 24 GB **+ 32 GB RAM**) | — | **not Codex-compatible** (see below); runs via a taskdef entry-point override, not a registry row |

Details (the exact flags, the VRAM math, deploy notes) live in each row's `_note` field in
`server/models.json` — the file is the source of truth; this table is the index.

## Sizing notes

- **The 14B fits a 24 GB A10G** (g5.xlarge) with room for a 32k context and curated MCP. It is the
  cheap, low-friction default.
- **The 30B MoE needs 24 GB VRAM plus headroom**: 16.85 GiB of AWQ weights, and on the A10G that
  leaves ~16k KV (too small for Codex's prompt+MCP+files+history), so it runs `--enforce-eager` at
  0.95 gpu-mem-util to buy KV space at a ~10–20% decode-speed cost. On the 48 GB L40S the same
  weights leave real headroom, so full MCP + more concurrent sessions fit without the eager tax.
- **Qwen3.8-27B is an Ada-only model**: its gated-DeltaNet hybrid + MTP kernels need sm_89, i.e. the
  L40S (g6e.xlarge), not the A10G. That is a hard requirement, not a preference.
- **INT4 vs FP8 on the same 27B**: halving weight bytes per token cut decode time ~40% (71.4 vs
  50.7 tok/s wall-clock mean, same box, 2026-10-12) and freed ~10 GiB, which the 256k context and
  fp8 KV cache put to work. The one subtlety is the MTP head: a naive 4-bit quantization drops the
  drafter, so the INT4 row uses the RedHatAI checkpoint that keeps lm_head + MTP head at BF16 — and
  that checkpoint's speculator registers as `method: "mtp"`, not `qwen3_5_mtp` (the FP8 name).
  Full numbers: [performance.md](performance.md); decision rationale:
  [ADR-0002](design-decisions/ADR-0002-quantization-and-speculative-decoding.md).
- **`kv_cache_dtype=fp8`** is a separate, compounding lever from weight quantization — it roughly
  doubles concurrent-session headroom on Ampere-class GPUs and is set per row in the registry.

## Model ↔ Codex compatibility

Two independent layers decide whether a model can drive Codex:

**1. The API layer (all models, all vLLM builds 0.30.0).** Codex speaks the OpenAI Responses API
with a `developer` role and typed `input_text` content chunks; vLLM 0.30.0 rejects both with `400`.
The client-side [role-proxy](../bin/codex-role-proxy.py) rewrites both on the way through (plus
strips echoed `reasoning` items and merges system messages), so *any* model is reachable — this is
a transport problem, solved once.

**2. The tool-format layer (model-specific).** Codex's function-calling format is OpenAI-style.
- **Qwen models** expose it through vLLM's `qwen3_coder` / `hermes` tool-call parsers → **work**.
- **Mistral models (Devstral)** do not: `mistral_common` requires 9-char alphanumeric tool-call ids
  and rejects Codex's `call_<hex>` ids, plus a `justification`/`sandbox_permissions` tool-schema
  mismatch. Devstral remains a strong agentic-coding model — just not for Codex; drive it with
  OpenHands / mini-SWE-agent / Mistral `vibe`. For Codex on the same g5.2xlarge box, `coder-30b`
  is the drop-in equivalent.

Switching models is a one-variable change (`model_key`) + redeploy — the reason the registry
exists is precisely that trying the next model in the landscape (e.g. a larger MoE coder) should
cost a Terraform change, not a rewrite.
